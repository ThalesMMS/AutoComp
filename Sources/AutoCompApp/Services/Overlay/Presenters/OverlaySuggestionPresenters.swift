import AppKit
import AutoCompCore

@MainActor
final class UnavailableNativeInlinePresenter: NativeInlineSuggestionPresenting {
    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        false
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {}
    func update(_ suggestion: Suggestion, for context: TextContext) {}
    func hide() {}
}

@MainActor
final class SimpleCaretPopupSuggestionPresenter: VisualInlineSuggestionPresenting {
    private var panel: NSPanel?
    private var contentView: SimpleCaretPopupContentView?
    private var fontSizeResolver = GhostFontSizeResolver()
    private let shortcutSettingsStore: KeyboardShortcutSettingsStore
    private let hintsProvider: OverlayShortcutHintsProvider

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutSettingsStore = shortcutSettingsStore
        self.hintsProvider = hintsProvider
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        layout(for: suggestion, context: context) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        guard let layout = layout(for: suggestion, context: context) else {
            GeometryDebug.log("tier=simpleCaretPopup rejected app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
            hide()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let contentView = contentView ?? makeContentView(for: panel)
        self.contentView = contentView

        let shortcutSettings = shortcutSettingsStore.load()
        let hints = hintsProvider.hints(from: shortcutSettings)

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
        GeometryDebug.log("tier=simpleCaretPopup hide hasPanel=\(panel != nil)")
        fontSizeResolver.reset()
        panel?.orderOut(nil)
    }

    private func layout(for suggestion: Suggestion, context: TextContext) -> SimpleCaretPopupLayout? {
        guard let anchorRect = context.caretRect
            ?? context.previousGlyphRect
            ?? context.nextGlyphRect
            ?? context.lineReferenceRect
            ?? context.focusedElementRect else {
            return nil
        }

        let screen = OverlayGeometry.screen(containingAccessibilityRect: anchorRect)
        let mainScreenFrame = NSScreen.screens.first?.frame ?? screen.frame
        return SimpleCaretPopupLayout.resolve(
            text: suggestion.visibleText,
            context: context,
            font: fontSizeResolver.font(for: context),
            screenFrame: mainScreenFrame,
            visibleFrame: screen.visibleFrame,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private func makePanel() -> NSPanel {
        FloatingSuggestionPanelFactory.makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 32),
            level: .popUpMenu
        )
    }

    private func makeContentView(for panel: NSPanel) -> SimpleCaretPopupContentView {
        let view = SimpleCaretPopupContentView(frame: NSRect(x: 0, y: 0, width: 180, height: 32))
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 32)
        panel.contentView = view
        return view
    }
}

@MainActor
final class MultiSuggestionPopupPresenter: VisualInlineSuggestionPresenting {
    private var panel: NSPanel?
    private var contentView: MultiSuggestionPopupContentView?
    private var fontSizeResolver = GhostFontSizeResolver()
    private let shortcutSettingsStore: KeyboardShortcutSettingsStore
    private let hintsProvider: OverlayShortcutHintsProvider

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutSettingsStore = shortcutSettingsStore
        self.hintsProvider = hintsProvider
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        suggestion.hasMultipleAlternatives && layout(for: suggestion, context: context) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        guard let layout = layout(for: suggestion, context: context) else {
            GeometryDebug.log("tier=multiSuggestionPopup rejected app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
            hide()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let contentView = contentView ?? makeContentView(for: panel)
        self.contentView = contentView
        let shortcutSettings = shortcutSettingsStore.load()
        let hints = hintsProvider.hints(from: shortcutSettings)

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
        GeometryDebug.log("tier=multiSuggestionPopup hide hasPanel=\(panel != nil)")
        fontSizeResolver.reset()
        panel?.orderOut(nil)
    }

    private func layout(for suggestion: Suggestion, context: TextContext) -> MultiSuggestionPopupLayout? {
        guard let anchorRect = context.caretRect
            ?? context.previousGlyphRect
            ?? context.nextGlyphRect
            ?? context.lineReferenceRect
            ?? context.focusedElementRect else {
            return nil
        }

        let screen = OverlayGeometry.screen(containingAccessibilityRect: anchorRect)
        let mainScreenFrame = NSScreen.screens.first?.frame ?? screen.frame
        return MultiSuggestionPopupLayout.resolve(
            suggestion: suggestion,
            context: context,
            font: fontSizeResolver.font(for: context),
            screenFrame: mainScreenFrame,
            visibleFrame: screen.visibleFrame,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private func makePanel() -> NSPanel {
        FloatingSuggestionPanelFactory.makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            level: .popUpMenu
        )
    }

    private func makeContentView(for panel: NSPanel) -> MultiSuggestionPopupContentView {
        let view = MultiSuggestionPopupContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        panel.contentView = view
        return view
    }
}

@MainActor
final class VisualInlineOverlayPresenter: VisualInlineSuggestionPresenting {
    private var panel: NSPanel?
    private var contentView: InlineGhostTextView?
    private var fontSizeResolver = GhostFontSizeResolver()
    private let maxWidth: CGFloat = 520
    private let shortcutSettingsStore: KeyboardShortcutSettingsStore
    private let hintsProvider: OverlayShortcutHintsProvider

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutSettingsStore = shortcutSettingsStore
        self.hintsProvider = hintsProvider
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        layout(for: suggestion, context: context) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        let resolution = layoutResolution(for: suggestion, context: context)
        guard let layout = resolution.layout else {
            GeometryDebug.log("tier=visualInlineOverlay rejected app=\(context.app.displayName) bundle=\(context.app.bundleID) reason=\(resolution.rejectionReason ?? "unknown") context=\(context.geometryDebugDescription)")
            hide()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let contentView = contentView ?? makeContentView(for: panel)
        self.contentView = contentView
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let font = font(for: context)
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

        let shortcutSettings = shortcutSettingsStore.load()
        let hints = hintsProvider.hints(from: shortcutSettings)

        contentView.update(
            layout: ghostLayout,
            font: font,
            textColor: ghostTextColor(),
            textDirection: textDirection,
            acceptKeycapHint: hints.acceptNextWord
        )
        panel.setFrame(ghostLayout.panelFrame, display: true)
        GeometryDebug.log("tier=visualInlineOverlay source=\(layout.source.rawValue) placement=\(ghostLayout.placementReason.rawValue) app=\(context.app.displayName) bundle=\(context.app.bundleID) panel=\(ghostLayout.panelFrame) context=\(context.geometryDebugDescription)")
        panel.orderFrontRegardless()
    }

    func hide() {
        GeometryDebug.log("tier=visualInlineOverlay hide hasPanel=\(panel != nil)")
        fontSizeResolver.reset()
        panel?.orderOut(nil)
    }

    private func layout(for suggestion: Suggestion, context: TextContext) -> InlinePreviewLayout? {
        layoutResolution(for: suggestion, context: context).layout
    }

    private func layoutResolution(for suggestion: Suggestion, context: TextContext) -> InlinePreviewResolution {
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

        guard let anchorRect = context.caretRect
            ?? context.previousGlyphRect
            ?? context.nextGlyphRect
            ?? context.lineReferenceRect
            ?? context.focusedElementRect else {
            return InlinePreviewResolution(rejectionReason: "missing-inline-anchor")
        }

        let screen = OverlayGeometry.screen(containingAccessibilityRect: anchorRect)
        let mainScreenFrame = NSScreen.screens.first?.frame ?? screen.frame
        let font = font(for: context)
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let resolution = InlinePreviewGeometry.resolve(
            context: context,
            contentSize: preferredSize(for: suggestion.visibleText, context: context, resolvedFont: font),
            screenFrame: mainScreenFrame,
            visibleFrame: screen.visibleFrame,
            screenFrames: NSScreen.screens.map(\.frame),
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
            visibleFrame: screen.visibleFrame,
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

    private func preferredSize(for text: String, context: TextContext, resolvedFont: NSFont? = nil) -> NSSize {
        let font = resolvedFont ?? font(for: context)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        let referenceHeight = InlinePreviewGeometry.referenceHeight(for: context)
        return NSSize(
            width: min(maxWidth, max(1, ceil(measured.width + 2))),
            height: max(16, ceil(max(referenceHeight, measured.height)))
        )
    }

    private func font(for context: TextContext) -> NSFont {
        fontSizeResolver.font(for: context)
    }

    private func ghostTextColor() -> NSColor {
        GhostTextColorResolver.color()
    }

    private func makePanel() -> NSPanel {
        FloatingSuggestionPanelFactory.makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 18)
        )
    }

    private func makeContentView(for panel: NSPanel) -> InlineGhostTextView {
        let view = InlineGhostTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 18))
        panel.contentView = view
        return view
    }
}

@MainActor
final class MirrorWindowSuggestionPresenter: SuggestionTierPresenting {
    private var panel: NSPanel?
    private var contentView: MirrorSuggestionOverlayContentView?
    private let mirrorOrigin = CGPoint(x: 24, y: 64)
    private let shortcutSettingsStore: KeyboardShortcutSettingsStore
    private let hintsProvider: OverlayShortcutHintsProvider

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutSettingsStore = shortcutSettingsStore
        self.hintsProvider = hintsProvider
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let contentView = contentView ?? makeContentView(for: panel)
        self.contentView = contentView

        let shortcutSettings = shortcutSettingsStore.load()
        let hints = hintsProvider.hints(from: shortcutSettings)

        contentView.update(text: suggestion.visibleText, appName: context.app.displayName, acceptKeycapHint: hints.acceptNextWord)
        panel.setFrame(NSRect(origin: mirrorOrigin, size: contentView.preferredSize), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        FloatingSuggestionPanelFactory.makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 42)
        )
    }

    private func makeContentView(for panel: NSPanel) -> MirrorSuggestionOverlayContentView {
        let view = MirrorSuggestionOverlayContentView(frame: NSRect(origin: .zero, size: NSSize(width: 420, height: 42)))
        panel.contentView = view
        return view
    }
}
