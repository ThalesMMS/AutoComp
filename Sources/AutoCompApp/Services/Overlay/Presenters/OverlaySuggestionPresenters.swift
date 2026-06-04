import AppKit
import AutoCompCore

@MainActor
final class SystemNativeInlineFallbackPresenter: NativeInlineSuggestionPresenting {
    static let unsupportedReason = "cross-app-native-inline-unavailable"
    static let fallbackDiagnostic = FallbackDiagnostic(
        symbol: "SystemNativeInlineFallbackPresenter",
        classification: .platformUnavailable,
        reason: unsupportedReason,
        userMessage: "Native inline presentation is unavailable for cross-app text fields; AutoComp uses overlay tiers instead.",
        remediation: "Use visual inline, caret popup, or mirror overlay presentation until a host-specific native inline integration is available."
    )

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        availability(for: suggestion, context: context).canPresent
    }

    func availability(for suggestion: Suggestion, context: TextContext) -> NativeInlinePresentationAvailability {
        GeometryDebug.log("tier=nativeInline unavailable reason=\(Self.unsupportedReason) app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
        return .unsupported(reason: Self.unsupportedReason)
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        GeometryDebug.log("tier=nativeInline ignored action=show reason=\(Self.unsupportedReason) app=\(context.app.displayName) bundle=\(context.app.bundleID)")
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        GeometryDebug.log("tier=nativeInline ignored action=update reason=\(Self.unsupportedReason) app=\(context.app.displayName) bundle=\(context.app.bundleID)")
    }

    func hide() {
        GeometryDebug.log("tier=nativeInline hide reason=\(Self.unsupportedReason)")
    }
}

@MainActor
final class SimpleCaretPopupSuggestionPresenter: VisualInlineSuggestionPresenting {
    private let panelHost: OverlayPanelHost<SimpleCaretPopupContentView>
    private var fontSizeResolver = GhostFontSizeResolver()
    private let shortcutHintResolver: OverlayShortcutHintResolver

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutHintResolver = OverlayShortcutHintResolver(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.panelHost = OverlayPanelHost(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 32),
            level: .popUpMenu
        ) { panel in
            let view = SimpleCaretPopupContentView(frame: NSRect(x: 0, y: 0, width: 180, height: 32))
            view.frame = NSRect(x: 0, y: 0, width: 180, height: 32)
            panel.contentView = view
            return view
        }
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        layout(for: suggestion, context: context) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        guard let layout = layout(for: suggestion, context: context) else {
            OverlayPresenterLog.rejected(tier: "simpleCaretPopup", context: context)
            hide()
            return
        }

        let hostedPanel = panelHost.resolve()
        let panel = hostedPanel.panel
        let contentView = hostedPanel.contentView
        let hints = shortcutHintResolver.hints()

        contentView.update(
            text: SimpleCaretPopupLayout.normalized(suggestion.visibleText),
            acceptKeycapHint: hints.acceptNextWord,
            size: layout.panelFrame.size
        )
        panel.setFrame(layout.panelFrame, display: true)
        GeometryDebug.log("tier=simpleCaretPopup placement=\(layout.placementReason.rawValue) app=\(context.app.displayName) bundle=\(context.app.bundleID) panel=\(layout.panelFrame) context=\(context.geometryDebugDescription)")
        panel.orderFrontRegardless()
    }

    func hide() {
        OverlayPresenterLog.hide(tier: "simpleCaretPopup", hasPanel: panelHost.hasPanel)
        fontSizeResolver.reset()
        panelHost.hide()
    }

    private func layout(for suggestion: Suggestion, context: TextContext) -> SimpleCaretPopupLayout? {
        guard let screenContext = OverlayPresenterGeometry.screenContext(for: context) else {
            return nil
        }

        return SimpleCaretPopupLayout.resolve(
            text: suggestion.visibleText,
            context: context,
            font: fontSizeResolver.font(for: context),
            screenFrame: screenContext.mainScreenFrame,
            visibleFrame: screenContext.visibleFrame,
            screenFrames: screenContext.screenFrames
        )
    }
}

@MainActor
final class MultiSuggestionPopupPresenter: VisualInlineSuggestionPresenting {
    private let panelHost: OverlayPanelHost<MultiSuggestionPopupContentView>
    private var fontSizeResolver = GhostFontSizeResolver()
    private let shortcutHintResolver: OverlayShortcutHintResolver

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutHintResolver = OverlayShortcutHintResolver(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.panelHost = OverlayPanelHost(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            level: .popUpMenu
        ) { panel in
            let view = MultiSuggestionPopupContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
            panel.contentView = view
            return view
        }
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        suggestion.hasMultipleAlternatives && layout(for: suggestion, context: context) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        guard let layout = layout(for: suggestion, context: context) else {
            OverlayPresenterLog.rejected(tier: "multiSuggestionPopup", context: context)
            hide()
            return
        }

        let hostedPanel = panelHost.resolve()
        let panel = hostedPanel.panel
        let contentView = hostedPanel.contentView
        let hints = shortcutHintResolver.hints()

        contentView.update(
            alternatives: suggestion.alternatives,
            selectedIndex: suggestion.selectedAlternativeIndex,
            acceptKeycapHint: hints.acceptNextWord,
            previousKeycapHint: hints.previousSuggestion,
            nextKeycapHint: hints.nextSuggestion,
            size: layout.panelFrame.size
        )
        panel.setFrame(layout.panelFrame, display: true)
        GeometryDebug.log("tier=multiSuggestionPopup placement=\(layout.placementReason.rawValue) selected=\(suggestion.selectedAlternativeIndex) count=\(suggestion.alternatives.count) app=\(context.app.displayName) bundle=\(context.app.bundleID) panel=\(layout.panelFrame) context=\(context.geometryDebugDescription)")
        panel.orderFrontRegardless()
    }

    func hide() {
        OverlayPresenterLog.hide(tier: "multiSuggestionPopup", hasPanel: panelHost.hasPanel)
        fontSizeResolver.reset()
        panelHost.hide()
    }

    private func layout(for suggestion: Suggestion, context: TextContext) -> MultiSuggestionPopupLayout? {
        guard let screenContext = OverlayPresenterGeometry.screenContext(for: context) else {
            return nil
        }

        return MultiSuggestionPopupLayout.resolve(
            suggestion: suggestion,
            context: context,
            font: fontSizeResolver.font(for: context),
            screenFrame: screenContext.mainScreenFrame,
            visibleFrame: screenContext.visibleFrame,
            screenFrames: screenContext.screenFrames
        )
    }
}

@MainActor
final class VisualInlineOverlayPresenter: VisualInlineSuggestionPresenting {
    private let panelHost: OverlayPanelHost<InlineGhostTextView>
    private var styleResolver = OverlayTextStyleResolver()
    private let maxWidth: CGFloat = 520
    private let shortcutHintResolver: OverlayShortcutHintResolver

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutHintResolver = OverlayShortcutHintResolver(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.panelHost = OverlayPanelHost(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 18)
        ) { panel in
            let view = InlineGhostTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 18))
            panel.contentView = view
            return view
        }
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        let style = style(for: context)
        return layout(for: suggestion, context: context, style: style) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        let style = style(for: context)
        let resolution = layoutResolution(for: suggestion, context: context, style: style)
        guard let layout = resolution.layout else {
            OverlayPresenterLog.rejected(
                tier: "visualInlineOverlay",
                context: context,
                reason: resolution.rejectionReason ?? "unknown"
            )
            hide()
            return
        }

        let hostedPanel = panelHost.resolve()
        let panel = hostedPanel.panel
        let contentView = hostedPanel.contentView
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let font = style.font
        let ghostLayout = layout.ghostTextLayout ?? InlineGhostTextLayout.resolve(
            text: suggestion.visibleText,
            font: font,
            textDirection: textDirection,
            anchorFrame: NSRect(origin: layout.origin, size: layout.size),
            inputFrame: layout.inputFrame,
            visibleFrame: NSRect(origin: layout.origin, size: layout.size),
            observedCharacterWidth: context.observedCharacterWidth,
            geometryQuality: context.caretGeometryQuality
        )

        let hints = shortcutHintResolver.hints()

        contentView.update(
            layout: ghostLayout,
            font: font,
            textColor: style.textColor,
            textDirection: textDirection,
            acceptKeycapHint: hints.acceptNextWord
        )
        panel.setFrame(ghostLayout.panelFrame, display: true)
        GeometryDebug.log("tier=visualInlineOverlay source=\(layout.source.rawValue) styleSource=\(style.source.rawValue) placement=\(ghostLayout.placementReason.rawValue) app=\(context.app.displayName) bundle=\(context.app.bundleID) panel=\(ghostLayout.panelFrame) context=\(context.geometryDebugDescription)")
        panel.orderFrontRegardless()
    }

    func hide() {
        OverlayPresenterLog.hide(tier: "visualInlineOverlay", hasPanel: panelHost.hasPanel)
        styleResolver.reset()
        panelHost.hide()
    }

    private func layout(
        for suggestion: Suggestion,
        context: TextContext,
        style: ResolvedOverlayTextStyle
    ) -> InlinePreviewLayout? {
        layoutResolution(for: suggestion, context: context, style: style).layout
    }

    private func layoutResolution(
        for suggestion: Suggestion,
        context: TextContext,
        style: ResolvedOverlayTextStyle
    ) -> InlinePreviewResolution {
        // Guardrail: only attempt inline overlay placement when caret geometry is trusted.
        // Otherwise force a safe popup (SimpleCaretPopup) or suppress entirely.
        let usesFocusedElementFallback = context.caretRect == nil
            && context.previousGlyphRect == nil
            && context.nextGlyphRect == nil
            && context.lineReferenceRect == nil
            && context.focusedElementRect != nil
        if !usesFocusedElementFallback {
            let trustDecision = CaretGeometryTrustEvaluator.default.evaluate(
                caretRect: context.caretRect,
                focusedElementRect: context.focusedElementRect,
                screenBounds: NSScreen.main?.frame,
                quality: context.caretGeometryQuality
            )
            switch trustDecision {
            case .allowInline:
                break
            case .forcePopup:
                return InlinePreviewResolution(rejectionReason: "caret-untrusted-force-popup")
            case .suppress:
                return InlinePreviewResolution(rejectionReason: "caret-untrusted-suppress")
            }
        }

        guard let screenContext = OverlayPresenterGeometry.screenContext(for: context) else {
            return InlinePreviewResolution(rejectionReason: "missing-inline-anchor")
        }

        let font = style.font
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let resolution = InlinePreviewGeometry.resolve(
            context: context,
            contentSize: preferredSize(for: suggestion.visibleText, context: context, resolvedFont: font),
            screenFrame: screenContext.mainScreenFrame,
            visibleFrame: screenContext.visibleFrame,
            screenFrames: screenContext.screenFrames,
            allowsLineWrapPlacement: true
        )
        guard let layout = resolution.layout else {
            return resolution
        }

        let ghostLayout = InlineGhostTextLayout.resolve(
            text: suggestion.visibleText,
            font: font,
            textDirection: textDirection,
            anchorFrame: NSRect(origin: layout.origin, size: layout.size),
            inputFrame: layout.inputFrame,
            visibleFrame: screenContext.visibleFrame,
            observedCharacterWidth: context.observedCharacterWidth,
            geometryQuality: context.caretGeometryQuality
        )
        return InlinePreviewLayout(
            origin: ghostLayout.panelFrame.origin,
            size: ghostLayout.panelFrame.size,
            source: layout.source,
            inputFrame: layout.inputFrame,
            ghostTextLayout: ghostLayout
        ).resolution
    }

    private func preferredSize(for text: String, context: TextContext, resolvedFont: NSFont) -> NSSize {
        let font = resolvedFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        let referenceHeight = InlinePreviewGeometry.referenceHeight(for: context)
        return NSSize(
            width: min(maxWidth, max(1, ceil(measured.width + 2))),
            height: max(16, ceil(max(referenceHeight, measured.height)))
        )
    }

    private func style(for context: TextContext) -> ResolvedOverlayTextStyle {
        styleResolver.style(for: context, appearance: NSApp?.effectiveAppearance)
    }
}

@MainActor
final class MirrorWindowSuggestionPresenter: SuggestionTierPresenting {
    private let panelHost: OverlayPanelHost<MirrorSuggestionOverlayContentView>
    private let mirrorOrigin = CGPoint(x: 24, y: 64)
    private let shortcutHintResolver: OverlayShortcutHintResolver

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutHintResolver = OverlayShortcutHintResolver(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.panelHost = OverlayPanelHost(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 42)
        ) { panel in
            let view = MirrorSuggestionOverlayContentView(
                frame: NSRect(origin: .zero, size: NSSize(width: 420, height: 42))
            )
            panel.contentView = view
            return view
        }
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        let hostedPanel = panelHost.resolve()
        let panel = hostedPanel.panel
        let contentView = hostedPanel.contentView
        let hints = shortcutHintResolver.hints()

        contentView.update(text: suggestion.visibleText, appName: context.app.displayName, acceptKeycapHint: hints.acceptNextWord)
        panel.setFrame(NSRect(origin: mirrorOrigin, size: contentView.preferredSize), display: true)
        GeometryDebug.log("tier=mirrorWindow placement=fixed app=\(context.app.displayName) bundle=\(context.app.bundleID) panel=\(panel.frame) context=\(context.geometryDebugDescription)")
        panel.orderFrontRegardless()
    }

    func hide() {
        OverlayPresenterLog.hide(tier: "mirrorWindow", hasPanel: panelHost.hasPanel)
        panelHost.hide()
    }
}
