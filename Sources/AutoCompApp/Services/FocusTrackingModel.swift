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

protocol ScreenOCRGeometryFallbackResolving: AnyObject, Sendable {
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
    private(set) var capabilityFlickerStats = FocusCapabilityFlickerStats()

    private let axHelper: AXHelper
    private let focusSnapshotResolver: any FocusSnapshotResolving
    private let textGeometryResolver: any AXTextGeometryResolving
    private let screenOCRGeometryFallbackResolver: any ScreenOCRGeometryFallbackResolving
    private let axCapabilitySnapshotRecorder: any AXCapabilitySnapshotRecording
    private let interactionPipelineSuspensionController: InteractionPipelineSuspensionController?
    private let safeOverlayModeEnabled: Bool
    private let screenOCRGeometryFallbackTimeout: TimeInterval
    private var lastStableFieldIdentity: StableFieldIdentity?
    private var lastTrackedFocusIdentity: TrackedFocusIdentity?
    private var capabilityFlickerGate = FocusCapabilityFlickerGate()

    init(
        axHelper: AXHelper = AXHelper(),
        focusSnapshotResolver: (any FocusSnapshotResolving)? = nil,
        textGeometryResolver: (any AXTextGeometryResolving)? = nil,
        screenOCRGeometryFallbackResolver: any ScreenOCRGeometryFallbackResolving = ScreenOCRGeometryFallbackResolver(),
        axCapabilitySnapshotRecorder: any AXCapabilitySnapshotRecording = AXCapabilitySnapshotRecorder(),
        interactionPipelineSuspensionController: InteractionPipelineSuspensionController? = nil,
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled,
        screenOCRGeometryFallbackTimeout: TimeInterval = 1.5
    ) {
        self.axHelper = axHelper
        self.focusSnapshotResolver = focusSnapshotResolver ?? FocusSnapshotResolver(axHelper: axHelper)
        self.textGeometryResolver = textGeometryResolver ?? AXTextGeometryResolver(axHelper: axHelper)
        self.screenOCRGeometryFallbackResolver = screenOCRGeometryFallbackResolver
        self.axCapabilitySnapshotRecorder = axCapabilitySnapshotRecorder
        self.interactionPipelineSuspensionController = interactionPipelineSuspensionController
        self.safeOverlayModeEnabled = safeOverlayModeEnabled
        self.screenOCRGeometryFallbackTimeout = max(0.05, screenOCRGeometryFallbackTimeout)
    }

    func currentContext() async throws -> TextContext {
        if interactionPipelineSuspensionController?.isSuspended == true {
            let error = AXTextContextError.interactionPipelineSuspended
            _ = await publishRejection(error)
            GeometryDebug.log("ax rejected reason=pipeline-suspended")
            throw error
        }

        lastFocusContextLatencyReport = nil
        var resolvedFocusSnapshot: AXFocusSnapshot?
        var resolvedGeometry: AXTextGeometrySnapshot?
        do {
            let axCaptureStartedAt = ContinuousClock.now
            let focusSnapshot = try focusSnapshotResolver.resolve()
            resolvedFocusSnapshot = focusSnapshot
            lastDomainResolution = focusSnapshot.domainResolution
            let axCaptureMs = axCaptureStartedAt.duration(to: .now).milliseconds
            let geometryStartedAt = ContinuousClock.now
            var geometry = textGeometryResolver.resolve(snapshot: focusSnapshot)
            resolvedGeometry = geometry
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
               let authoritativeText = textBeforeCursor {
                let searchRect = axHelper.ancestorContentRect(for: focusSnapshot.focusedElement)
                let fallbackResult = await AsyncTimeout.run(
                    seconds: screenOCRGeometryFallbackTimeout,
                    onTimeout: {
                        GeometryDebug.log("ax-fallback source=screenOCR-geometry status=resolver-timeout")
                    },
                    operation: { [screenOCRGeometryFallbackResolver] in
                        await screenOCRGeometryFallbackResolver.resolve(
                            searchRect: searchRect,
                            authoritativeText: authoritativeText
                        )
                    }
                )
                let fallback: ScreenOCRGeometryFallback?
                switch fallbackResult {
                case .completed(let resolvedFallback):
                    fallback = resolvedFallback
                case .timedOut:
                    fallback = nil
                }

                if let fallback {
                    geometry.focusedElementRect = fallback.focusedElementRect
                    geometry.caretRect = fallback.caretRect
                    geometry.previousGlyphRect = fallback.previousGlyphRect
                    geometry.nextGlyphRect = nil
                    geometry.lineReferenceRect = fallback.previousGlyphRect
                    geometry.caretGeometryQuality = .screenOCR
                    geometry.caretGeometryProvenance = .screenOCR
                    geometry.coordinateSpace = .accessibilityGlobal
                    geometry.observedCharacterWidth = nil
                    resolvedGeometry = geometry
                    captureSources.insert(.screenOCR)
                    GeometryDebug.log("ax-fallback source=screenOCR-geometry focusedElementRect=\(fallback.focusedElementRect) caretRect=\(fallback.caretRect)")
                }
            }
            let geometryMs = geometryStartedAt.duration(to: .now).milliseconds
            lastFocusContextLatencyReport = FocusContextLatencyReport(
                axCaptureMs: axCaptureMs,
                geometryMs: geometryMs
            )
            if axCapabilitySnapshotRecorder.isEnabled {
                axCapabilitySnapshotRecorder.record(
                    focusSnapshot: focusSnapshot,
                    geometry: geometry,
                    captureSources: captureSources,
                    capabilityPresence: axHelper.capabilityPresence(for: focusSnapshot.focusedElement)
                )
            }

            guard let textBeforeCursor else {
                GeometryDebug.log("ax rejected reason=no-readable-text role=\(axHelper.stringAttribute(kAXRoleAttribute, from: focusSnapshot.focusedElement) ?? "nil") subrole=\(axHelper.stringAttribute(kAXSubroleAttribute, from: focusSnapshot.focusedElement) ?? "nil") selectedRange=\(String(describing: selectedRange)) textLength=\(focusSnapshot.textLength)")
                SuggestionPipelineLog.log("context-capture-rejected", fields: [
                    "reason=no-readable-text",
                    "appBundle=\(focusSnapshot.bundleID)",
                    "domain=\(focusSnapshot.domain ?? "nil")",
                    "domainResolution=\(focusSnapshot.domainResolution.diagnosticValue)",
                    "role=\(focusSnapshot.role ?? "nil")",
                    "subrole=\(focusSnapshot.subrole ?? "nil")",
                    "selectedRange=\(selectedRange.map { "\($0.location):\($0.length)" } ?? "nil")",
                    "textLength=\(focusSnapshot.textLength)",
                    "googleDocsElement=\(focusSnapshot.isGoogleDocsElement)"
                ])
                throw AXTextContextError.noReadableText
            }

            GeometryDebug.log(
                "ax app=\(focusSnapshot.displayName) bundle=\(focusSnapshot.bundleID) domain=\(focusSnapshot.domain ?? "nil") selectedRange=\(String(describing: selectedRange)) focusedElementRect=\(String(describing: geometry.focusedElementRect)) caretRect=\(String(describing: geometry.caretRect)) previousGlyphRect=\(String(describing: geometry.previousGlyphRect)) nextGlyphRect=\(String(describing: geometry.nextGlyphRect)) caretGeometryQuality=\(geometry.caretGeometryQuality.rawValue) provenance=\(geometry.caretGeometryProvenance.rawValue) coordinateSpace=\(geometry.coordinateSpace.rawValue) observedCharacterWidth=\(String(describing: geometry.observedCharacterWidth))"
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
                caretGeometryProvenance: geometry.caretGeometryProvenance,
                caretGeometryCoordinateSpace: geometry.coordinateSpace,
                observedCharacterWidth: geometry.observedCharacterWidth,
                languageHint: Locale.current.language.languageCode?.identifier,
                captureSources: captureSources
            )
            SuggestionPipelineLog.log("context-capture-success", fields: [
                "appBundle=\(focusSnapshot.bundleID)",
                "domain=\(focusSnapshot.domain ?? "nil")",
                "domainResolution=\(focusSnapshot.domainResolution.diagnosticValue)",
                "role=\(focusSnapshot.role ?? "nil")",
                "subrole=\(focusSnapshot.subrole ?? "nil")",
                "textLength=\(focusSnapshot.textLength)",
                "googleDocsElement=\(focusSnapshot.isGoogleDocsElement)",
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
            return await publishContext(context)
        } catch {
            if let preservedContext = await publishRejection(
                error,
                focusSnapshot: resolvedFocusSnapshot,
                geometry: resolvedGeometry
            ) {
                SuggestionPipelineLog.log("context-capability-flicker-suppressed", fields: [
                    "reason=\(capabilityFlickerStats.lastReason ?? "unknown")"
                ])
                return preservedContext
            }
            SuggestionPipelineLog.log("context-capture-failed", fields: [
                "error=\(SuggestionPipelineLog.privacySafeErrorSummary(error))"
            ])
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
        capabilityFlickerGate.recordSuccessfulRead()
        capabilityFlickerStats = capabilityFlickerGate.stats
        return publishedContext
    }

    @MainActor
    private func publishRejection(
        _ error: Error,
        focusSnapshot: AXFocusSnapshot? = nil,
        geometry: AXTextGeometrySnapshot? = nil
    ) -> TextContext? {
        let rejectedCapability = Self.capability(for: error)
        let sameStableField = isSameStableField(
            focusSnapshot: focusSnapshot,
            geometry: geometry
        )
        let decision = capabilityFlickerGate.evaluate(
            capability: rejectedCapability,
            sameStableField: sameStableField
        )
        capabilityFlickerStats = capabilityFlickerGate.stats
        if case .suppressTransient = decision, let snapshot {
            return snapshot.context
        }

        capability = rejectedCapability
        rejectionReason = Self.rejectionReason(for: error)
        stableFieldIdentity = nil
        snapshot = nil
        lastDomainResolution = nil
        return nil
    }

    @MainActor
    private func isSameStableField(
        focusSnapshot: AXFocusSnapshot?,
        geometry: AXTextGeometrySnapshot?
    ) -> Bool {
        guard let previousContext = snapshot?.context,
              let focusSnapshot,
              previousContext.app == focusSnapshot.app,
              previousContext.domain == focusSnapshot.domain else {
            return false
        }
        if previousContext.focusedElementID == focusSnapshot.focusedElementID {
            return true
        }
        guard let previousIdentity = previousContext.stableFieldIdentity else {
            return false
        }
        let candidate = StableFieldIdentity(
            app: focusSnapshot.app,
            domain: focusSnapshot.domain,
            role: focusSnapshot.role,
            subrole: focusSnapshot.subrole,
            focusedElementFrame: geometry?.focusedElementRect
        )
        return previousIdentity.matchesStableTarget(candidate)
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
        case .accessibilityNotTrusted, .noFrontmostApplication, .noFocusedElement, .interactionPipelineSuspended:
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
        self.copy(stableFieldIdentity: stableFieldIdentity)
    }
}
