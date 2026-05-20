import ApplicationServices
import AppKit
import AutoCompCore
import Foundation

enum FocusFieldCapability: Equatable {
    case unknown
    case readableText
    case unreadableText
    case secureOrUnsupported
    case unavailable
}

struct FocusTrackingSnapshot: Equatable {
    let context: TextContext
    let focusChangeSequence: UInt64
    let capability: FocusFieldCapability
    let rejectionReason: String?
}

protocol FocusSnapshotResolving {
    func resolve() throws -> AXFocusSnapshot
}

extension FocusSnapshotResolver: FocusSnapshotResolving {}

protocol AXTextGeometryResolving {
    func resolve(snapshot: AXFocusSnapshot) -> AXTextGeometrySnapshot
    func shouldUseScreenOCRFallback(
        snapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot
    ) -> Bool
}

extension AXTextGeometryResolver: AXTextGeometryResolving {}

protocol ScreenOCRGeometryFallbackResolving: AnyObject {
    func resolve(searchRect: CGRect?, authoritativeText: String) async -> ScreenOCRGeometryFallback?
}

extension ScreenOCRGeometryFallbackResolver: ScreenOCRGeometryFallbackResolving {}

final class FocusTrackingModel: ObservableObject, TextContextProvider, @unchecked Sendable {
    @Published private(set) var snapshot: FocusTrackingSnapshot?
    @Published private(set) var focusChangeSequence: UInt64 = 0
    @Published private(set) var capability: FocusFieldCapability = .unknown
    @Published private(set) var rejectionReason: String?

    private let axHelper: AXHelper
    private let focusSnapshotResolver: any FocusSnapshotResolving
    private let textGeometryResolver: any AXTextGeometryResolving
    private let screenOCRGeometryFallbackResolver: any ScreenOCRGeometryFallbackResolving
    private var lastFocusIdentity: TrackedFocusIdentity?

    init(
        axHelper: AXHelper = AXHelper(),
        focusSnapshotResolver: (any FocusSnapshotResolving)? = nil,
        textGeometryResolver: (any AXTextGeometryResolving)? = nil,
        screenOCRGeometryFallbackResolver: any ScreenOCRGeometryFallbackResolving = ScreenOCRGeometryFallbackResolver()
    ) {
        self.axHelper = axHelper
        self.focusSnapshotResolver = focusSnapshotResolver ?? FocusSnapshotResolver(axHelper: axHelper)
        self.textGeometryResolver = textGeometryResolver ?? AXTextGeometryResolver(axHelper: axHelper)
        self.screenOCRGeometryFallbackResolver = screenOCRGeometryFallbackResolver
    }

    func currentContext() async throws -> TextContext {
        do {
            let focusSnapshot = try focusSnapshotResolver.resolve()
            var geometry = textGeometryResolver.resolve(snapshot: focusSnapshot)
            var selectedRange = focusSnapshot.selectedRange
            var textBeforeCursor = focusSnapshot.textBeforeCursor
            var captureSources: Set<TextCaptureSource> = [.accessibility]

            if textGeometryResolver.shouldUseScreenOCRFallback(
                snapshot: focusSnapshot,
                geometry: geometry
            ),
               let authoritativeText = textBeforeCursor,
               let fallback = await screenOCRGeometryFallbackResolver.resolve(
                searchRect: axHelper.ancestorContentRect(for: focusSnapshot.focusedElement),
                authoritativeText: authoritativeText
               ) {
                textBeforeCursor = fallback.textBeforeCursor
                selectedRange = NSRange(location: (fallback.textBeforeCursor as NSString).length, length: 0)
                geometry.focusedElementRect = fallback.focusedElementRect
                geometry.caretRect = fallback.caretRect
                geometry.previousGlyphRect = fallback.previousGlyphRect
                geometry.nextGlyphRect = nil
                geometry.lineReferenceRect = fallback.previousGlyphRect
                geometry.caretGeometryQuality = .screenOCR
                geometry.observedCharacterWidth = nil
                captureSources.insert(.screenOCR)
                GeometryDebug.log("ax-fallback source=screenOCR text=\(fallback.textBeforeCursor) focusedElementRect=\(fallback.focusedElementRect) caretRect=\(fallback.caretRect)")
            }

            guard let textBeforeCursor else {
                GeometryDebug.log("ax rejected reason=no-readable-text role=\(axHelper.stringAttribute(kAXRoleAttribute, from: focusSnapshot.focusedElement) ?? "nil") subrole=\(axHelper.stringAttribute(kAXSubroleAttribute, from: focusSnapshot.focusedElement) ?? "nil") selectedRange=\(String(describing: selectedRange)) textLength=\(focusSnapshot.textLength)")
                throw AXTextContextError.noReadableText
            }

            GeometryDebug.log(
                "ax app=\(focusSnapshot.displayName) bundle=\(focusSnapshot.bundleID) domain=\(focusSnapshot.domain ?? "nil") selectedRange=\(String(describing: selectedRange)) focusedElementRect=\(String(describing: geometry.focusedElementRect)) caretRect=\(String(describing: geometry.caretRect)) previousGlyphRect=\(String(describing: geometry.previousGlyphRect)) nextGlyphRect=\(String(describing: geometry.nextGlyphRect)) caretGeometryQuality=\(geometry.caretGeometryQuality.rawValue) observedCharacterWidth=\(String(describing: geometry.observedCharacterWidth))"
            )

            let context = TextContext(
                app: focusSnapshot.app,
                domain: focusSnapshot.domain,
                focusedElementID: focusSnapshot.focusedElementID,
                textBeforeCursor: textBeforeCursor,
                selectedRange: selectedRange,
                caretRect: geometry.caretRect,
                focusedElementRect: geometry.focusedElementRect,
                previousGlyphRect: geometry.previousGlyphRect,
                nextGlyphRect: geometry.nextGlyphRect,
                lineReferenceRect: geometry.lineReferenceRect,
                caretGeometryQuality: geometry.caretGeometryQuality,
                observedCharacterWidth: geometry.observedCharacterWidth,
                languageHint: Locale.current.language.languageCode?.identifier,
                captureSources: captureSources
            )
            await publishContext(context)
            return context
        } catch {
            await publishRejection(error)
            throw error
        }
    }

    @MainActor
    private func publishContext(_ context: TextContext) {
        let trackedIdentity = TrackedFocusIdentity(context: context)
        if lastFocusIdentity?.matches(context) != true {
            focusChangeSequence += 1
        }
        lastFocusIdentity = trackedIdentity
        capability = .readableText
        rejectionReason = nil
        snapshot = FocusTrackingSnapshot(
            context: context,
            focusChangeSequence: focusChangeSequence,
            capability: capability,
            rejectionReason: rejectionReason
        )
    }

    @MainActor
    private func publishRejection(_ error: Error) {
        capability = Self.capability(for: error)
        rejectionReason = Self.rejectionReason(for: error)
        snapshot = nil
    }

    private static func capability(for error: Error) -> FocusFieldCapability {
        guard let contextError = error as? AXTextContextError else {
            return .unavailable
        }

        switch contextError {
        case .secureOrUnsupportedField:
            return .secureOrUnsupported
        case .noReadableText:
            return .unreadableText
        case .accessibilityNotTrusted, .noFrontmostApplication, .noFocusedElement:
            return .unavailable
        }
    }

    private static func rejectionReason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private struct TrackedFocusIdentity {
    let app: AppIdentity
    let domain: String?
    let focusIdentity: FocusIdentity

    init(context: TextContext) {
        app = context.app
        domain = context.domain
        focusIdentity = FocusIdentity(context: context)
    }

    func matches(_ context: TextContext) -> Bool {
        app == context.app
            && domain == context.domain
            && focusIdentity.matches(FocusIdentity(context: context))
    }
}
