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
    let stableFieldIdentity: StableFieldIdentity?
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

protocol DomainResolutionReporting: AnyObject {
    var lastDomainResolution: BrowserDomainResolution? { get }
}

final class FocusTrackingModel: ObservableObject, TextContextProvider, FocusContextLatencyReporting, DomainResolutionReporting, @unchecked Sendable {
    @Published private(set) var snapshot: FocusTrackingSnapshot?
    @Published private(set) var stableFieldIdentity: StableFieldIdentity?
    @Published private(set) var focusChangeSequence: UInt64 = 0
    @Published private(set) var capability: FocusFieldCapability = .unknown
    @Published private(set) var rejectionReason: String?
    private(set) var lastFocusContextLatencyReport: FocusContextLatencyReport?
    private(set) var lastDomainResolution: BrowserDomainResolution?

    private let axHelper: AXHelper
    private let focusSnapshotResolver: any FocusSnapshotResolving
    private let textGeometryResolver: any AXTextGeometryResolving
    private let screenOCRGeometryFallbackResolver: any ScreenOCRGeometryFallbackResolving
    private let axCapabilitySnapshotRecorder: any AXCapabilitySnapshotRecording
    private let safeOverlayModeEnabled: Bool
    private var lastStableFieldIdentity: StableFieldIdentity?
    private var lastTrackedFocusIdentity: TrackedFocusIdentity?

    init(
        axHelper: AXHelper = AXHelper(),
        focusSnapshotResolver: (any FocusSnapshotResolving)? = nil,
        textGeometryResolver: (any AXTextGeometryResolving)? = nil,
        screenOCRGeometryFallbackResolver: any ScreenOCRGeometryFallbackResolving = ScreenOCRGeometryFallbackResolver(),
        axCapabilitySnapshotRecorder: any AXCapabilitySnapshotRecording = AXCapabilitySnapshotRecorder(),
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled
    ) {
        self.axHelper = axHelper
        self.focusSnapshotResolver = focusSnapshotResolver ?? FocusSnapshotResolver(axHelper: axHelper)
        self.textGeometryResolver = textGeometryResolver ?? AXTextGeometryResolver(axHelper: axHelper)
        self.screenOCRGeometryFallbackResolver = screenOCRGeometryFallbackResolver
        self.axCapabilitySnapshotRecorder = axCapabilitySnapshotRecorder
        self.safeOverlayModeEnabled = safeOverlayModeEnabled
    }

    func currentContext() async throws -> TextContext {
        lastFocusContextLatencyReport = nil
        do {
            let axCaptureStartedAt = ContinuousClock.now
            let focusSnapshot = try focusSnapshotResolver.resolve()
            lastDomainResolution = focusSnapshot.domainResolution
            let axCaptureMs = axCaptureStartedAt.duration(to: .now).appMilliseconds
            let geometryStartedAt = ContinuousClock.now
            var geometry = textGeometryResolver.resolve(snapshot: focusSnapshot)
            let selectedRange = focusSnapshot.selectedRange
            let textBeforeCursor = focusSnapshot.textBeforeCursor
            let textAfterCursor = focusSnapshot.textAfterCursor
            let selectedText = focusSnapshot.selectedText
            let fullTextWindow = focusSnapshot.fullTextWindow
            var captureSources: Set<TextCaptureSource> = [.accessibility]

            let shouldUseScreenOCRFallback = textGeometryResolver.shouldUseScreenOCRFallback(
                snapshot: focusSnapshot,
                geometry: geometry
            )
            if safeOverlayModeEnabled,
               shouldUseScreenOCRFallback {
                GeometryDebug.log("safe-overlay-mode active feature=screenOCR-geometry action=disabled")
            }

            if !safeOverlayModeEnabled,
               shouldUseScreenOCRFallback,
               let authoritativeText = textBeforeCursor,
               let fallback = await screenOCRGeometryFallbackResolver.resolve(
                searchRect: axHelper.ancestorContentRect(for: focusSnapshot.focusedElement),
                authoritativeText: authoritativeText
               ) {
                geometry.focusedElementRect = fallback.focusedElementRect
                geometry.caretRect = fallback.caretRect
                geometry.previousGlyphRect = fallback.previousGlyphRect
                geometry.nextGlyphRect = nil
                geometry.lineReferenceRect = fallback.previousGlyphRect
                geometry.caretGeometryQuality = .screenOCR
                geometry.observedCharacterWidth = nil
                captureSources.insert(.screenOCR)
                GeometryDebug.log("ax-fallback source=screenOCR-geometry focusedElementRect=\(fallback.focusedElementRect) caretRect=\(fallback.caretRect)")
            }
            let geometryMs = geometryStartedAt.duration(to: .now).appMilliseconds
            lastFocusContextLatencyReport = FocusContextLatencyReport(
                axCaptureMs: axCaptureMs,
                geometryMs: geometryMs
            )
            axCapabilitySnapshotRecorder.record(
                focusSnapshot: focusSnapshot,
                geometry: geometry,
                captureSources: captureSources,
                capabilityPresence: axHelper.capabilityPresence(for: focusSnapshot.focusedElement)
            )

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
                stableFieldIdentity: StableFieldIdentity(
                    app: focusSnapshot.app,
                    domain: focusSnapshot.domain,
                    role: focusSnapshot.role,
                    subrole: focusSnapshot.subrole,
                    focusedElementFrame: geometry.focusedElementRect
                ),
                textBeforeCursor: textBeforeCursor,
                textAfterCursor: textAfterCursor,
                selectedText: selectedText,
                fullTextWindow: fullTextWindow,
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
            return await publishContext(context)
        } catch {
            await publishRejection(error)
            throw error
        }
    }

    @MainActor
    private func publishContext(_ context: TextContext) -> TextContext {
        let sequencedStableIdentity: StableFieldIdentity?
        let trackedFocusIdentity = TrackedFocusIdentity(context: context)
        if let baseStableIdentity = context.stableFieldIdentity {
            let stableTargetMatches = lastStableFieldIdentity?.matchesStableTarget(baseStableIdentity) == true
            let shouldUseFocusFallback = baseStableIdentity.roundedFocusedElementFrame == nil
            let fallbackFocusMatches = shouldUseFocusFallback
                && lastTrackedFocusIdentity?.matches(context) == true
            if !stableTargetMatches && !fallbackFocusMatches {
                focusChangeSequence += 1
            }
            sequencedStableIdentity = baseStableIdentity.withFocusChangeSequence(focusChangeSequence)
        } else {
            if lastTrackedFocusIdentity?.matches(context) != true {
                focusChangeSequence += 1
            }
            sequencedStableIdentity = nil
        }
        let publishedContext = context.withStableFieldIdentity(sequencedStableIdentity)
        lastStableFieldIdentity = sequencedStableIdentity
        lastTrackedFocusIdentity = trackedFocusIdentity
        stableFieldIdentity = sequencedStableIdentity
        capability = .readableText
        rejectionReason = nil
        snapshot = FocusTrackingSnapshot(
            context: publishedContext,
            stableFieldIdentity: sequencedStableIdentity,
            focusChangeSequence: focusChangeSequence,
            capability: capability,
            rejectionReason: rejectionReason
        )
        return publishedContext
    }

    @MainActor
    private func publishRejection(_ error: Error) {
        capability = Self.capability(for: error)
        rejectionReason = Self.rejectionReason(for: error)
        stableFieldIdentity = nil
        snapshot = nil
        lastDomainResolution = nil
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

private extension TextContext {
    func withStableFieldIdentity(_ stableFieldIdentity: StableFieldIdentity?) -> TextContext {
        TextContext(
            id: id,
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            stableFieldIdentity: stableFieldIdentity,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            selectedText: selectedText,
            fullTextWindow: fullTextWindow,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            languageHint: languageHint,
            captureSources: captureSources,
            createdAt: createdAt
        )
    }
}
