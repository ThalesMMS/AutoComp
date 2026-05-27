import AppKit
import AutoCompCore
import SwiftUI

enum PreviewPresentationTier: Equatable {
    case nativeInline
    case multiSuggestionPopup
    case visualInlineOverlay
    case simpleCaretPopup
    case mirrorWindow
    case disabled
}

enum GeometryDebug {
    private static let logger = AutoCompLogger(category: "geometry")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--geometry-debug")
            || ProcessInfo.processInfo.environment["AUTOCOMP_GEOMETRY_DEBUG"] == "1"
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }
        let resolvedMessage = message()
        logger.info("AutoCompGeometry \(resolvedMessage)")
        if let data = "AutoCompGeometry \(resolvedMessage)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

@MainActor
protocol SuggestionTierPresenting: AnyObject {
    func show(_ suggestion: Suggestion, for context: TextContext)
    func update(_ suggestion: Suggestion, for context: TextContext)
    func hide()
}

@MainActor
protocol NativeInlineSuggestionPresenting: SuggestionTierPresenting {
    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool
}

@MainActor
protocol VisualInlineSuggestionPresenting: SuggestionTierPresenting {
    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool
}

@MainActor
enum FloatingSuggestionPanelFactory {
    static func makePanel(
        contentRect: NSRect,
        level: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    ) -> NSPanel {
        let panel = FloatingSuggestionPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }
}

private final class FloatingSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PreviewCoordinator: SuggestionPresenter {
    private let nativeInlinePresenter: NativeInlineSuggestionPresenting
    private let multiSuggestionPopupPresenter: VisualInlineSuggestionPresenting
    private let visualInlinePresenter: VisualInlineSuggestionPresenting
    private let simpleCaretPopupPresenter: VisualInlineSuggestionPresenting
    private let mirrorWindowPresenter: SuggestionTierPresenting
    private let activationIndicator: ActivationIndicatorPresenting
    private let focusDebugOverlayPresenter: FocusDebugOverlayPresenting
    private let safeOverlayModeEnabled: Bool
    private let overlayRecoveryAdvisor: OverlayRecoveryAdvisor?

    private(set) var activeTier: PreviewPresentationTier = .disabled

    init(
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled,
        overlayRecoveryAdvisor: OverlayRecoveryAdvisor? = nil,
        focusDebugOverlayPresenter: FocusDebugOverlayPresenting? = nil
    ) {
        self.nativeInlinePresenter = UnavailableNativeInlinePresenter()
        self.multiSuggestionPopupPresenter = MultiSuggestionPopupPresenter()
        self.visualInlinePresenter = VisualInlineOverlayPresenter()
        self.simpleCaretPopupPresenter = SimpleCaretPopupSuggestionPresenter()
        self.mirrorWindowPresenter = MirrorWindowSuggestionPresenter()
        self.activationIndicator = ActivationIndicatorController()
        self.focusDebugOverlayPresenter = focusDebugOverlayPresenter ?? FocusDebugOverlayController()
        self.safeOverlayModeEnabled = safeOverlayModeEnabled
        self.overlayRecoveryAdvisor = overlayRecoveryAdvisor
    }

    init(
        nativeInlinePresenter: NativeInlineSuggestionPresenting,
        visualInlinePresenter: VisualInlineSuggestionPresenting,
        mirrorWindowPresenter: SuggestionTierPresenting,
        multiSuggestionPopupPresenter: VisualInlineSuggestionPresenting? = nil,
        simpleCaretPopupPresenter: VisualInlineSuggestionPresenting? = nil,
        activationIndicator: ActivationIndicatorPresenting? = nil,
        focusDebugOverlayPresenter: FocusDebugOverlayPresenting? = nil,
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled,
        overlayRecoveryAdvisor: OverlayRecoveryAdvisor? = nil
    ) {
        self.nativeInlinePresenter = nativeInlinePresenter
        self.multiSuggestionPopupPresenter = multiSuggestionPopupPresenter ?? MultiSuggestionPopupPresenter()
        self.visualInlinePresenter = visualInlinePresenter
        self.simpleCaretPopupPresenter = simpleCaretPopupPresenter ?? SimpleCaretPopupSuggestionPresenter()
        self.mirrorWindowPresenter = mirrorWindowPresenter
        self.activationIndicator = activationIndicator ?? ActivationIndicatorController()
        self.focusDebugOverlayPresenter = focusDebugOverlayPresenter ?? FocusDebugOverlayController()
        self.safeOverlayModeEnabled = safeOverlayModeEnabled
        self.overlayRecoveryAdvisor = overlayRecoveryAdvisor
    }

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        present(suggestion, for: context, mode: mode, isUpdate: false)
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        present(suggestion, for: context, mode: mode, isUpdate: true)
    }

    func hide() {
        GeometryDebug.log("presenter-hide activeTier=\(activeTier)")
        activeTier = .disabled
        nativeInlinePresenter.hide()
        multiSuggestionPopupPresenter.hide()
        visualInlinePresenter.hide()
        simpleCaretPopupPresenter.hide()
        mirrorWindowPresenter.hide()
        activationIndicator.hide()
        focusDebugOverlayPresenter.hide()
    }

    func resolveTier(for suggestion: Suggestion, context: TextContext, mode: SuggestionDisplayMode) -> PreviewPresentationTier {
        guard mode != .disabled, !suggestion.visibleText.isEmpty else {
            return .disabled
        }
        if safeOverlayModeEnabled {
            switch mode {
            case .inline:
                if simpleCaretPopupPresenter.canPresent(suggestion, for: context) {
                    return .simpleCaretPopup
                }
                return .mirrorWindow
            case .mirrorWindow:
                return .mirrorWindow
            case .disabled:
                return .disabled
            }
        }

        if suggestion.hasMultipleAlternatives,
           multiSuggestionPopupPresenter.canPresent(suggestion, for: context) {
            return .multiSuggestionPopup
        }

        switch mode {
        case .inline:
            if nativeInlinePresenter.canPresent(suggestion, for: context) {
                return .nativeInline
            }
            if visualInlinePresenter.canPresent(suggestion, for: context) {
                return .visualInlineOverlay
            }
            if simpleCaretPopupPresenter.canPresent(suggestion, for: context) {
                return .simpleCaretPopup
            }
            return .mirrorWindow
        case .mirrorWindow:
            return .mirrorWindow
        case .disabled:
            return .disabled
        }
    }

    private func present(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode, isUpdate: Bool) {
        let nextTier = resolveTier(for: suggestion, context: context, mode: mode)
        if safeOverlayModeEnabled {
            GeometryDebug.log("safe-overlay-mode active feature=preview-tier mode=\(mode.rawValue) resolvedTier=\(nextTier)")
        }
        recordOverlayRecoverySignal(tier: nextTier, mode: mode)
        GeometryDebug.log("presenter-present update=\(isUpdate) previousTier=\(String(describing: activeTier)) mode=\(mode.rawValue) resolvedTier=\(nextTier) app=\(context.app.displayName) bundle=\(context.app.bundleID) visibleLength=\((suggestion.visibleText as NSString).length) context=\(context.geometryDebugDescription)")
        let shouldUpdateExistingTier = isUpdate && activeTier == nextTier
        hidePresenters(except: nextTier)
        activeTier = nextTier
        if nextTier == .disabled {
            activationIndicator.hide()
            focusDebugOverlayPresenter.hide()
        } else {
            activationIndicator.show(
                for: context,
                displayMode: nextTier == .mirrorWindow ? .mirrorWindow : mode
            )
            focusDebugOverlayPresenter.show(context: context, tier: nextTier)
        }

        switch nextTier {
        case .nativeInline:
            shouldUpdateExistingTier
                ? nativeInlinePresenter.update(suggestion, for: context)
                : nativeInlinePresenter.show(suggestion, for: context)
        case .multiSuggestionPopup:
            shouldUpdateExistingTier
                ? multiSuggestionPopupPresenter.update(suggestion, for: context)
                : multiSuggestionPopupPresenter.show(suggestion, for: context)
        case .visualInlineOverlay:
            shouldUpdateExistingTier
                ? visualInlinePresenter.update(suggestion, for: context)
                : visualInlinePresenter.show(suggestion, for: context)
        case .simpleCaretPopup:
            shouldUpdateExistingTier
                ? simpleCaretPopupPresenter.update(suggestion, for: context)
                : simpleCaretPopupPresenter.show(suggestion, for: context)
        case .mirrorWindow:
            shouldUpdateExistingTier
                ? mirrorWindowPresenter.update(suggestion, for: context)
                : mirrorWindowPresenter.show(suggestion, for: context)
        case .disabled:
            break
        }
    }

    private func recordOverlayRecoverySignal(tier: PreviewPresentationTier, mode: SuggestionDisplayMode) {
        guard mode == .inline,
              !safeOverlayModeEnabled else {
            return
        }

        switch tier {
        case .nativeInline, .multiSuggestionPopup, .visualInlineOverlay:
            overlayRecoveryAdvisor?.recordAdvancedOverlaySuccess()
        case .simpleCaretPopup, .mirrorWindow:
            overlayRecoveryAdvisor?.recordAdvancedOverlayFallback()
        case .disabled:
            break
        }
    }

    private func hidePresenters(except tier: PreviewPresentationTier) {
        GeometryDebug.log("presenter-hide-except keep=\(tier) activeTier=\(String(describing: activeTier))")
        if tier != .nativeInline {
            nativeInlinePresenter.hide()
        }
        if tier != .multiSuggestionPopup {
            multiSuggestionPopupPresenter.hide()
        }
        if tier != .visualInlineOverlay {
            visualInlinePresenter.hide()
        }
        if tier != .simpleCaretPopup {
            simpleCaretPopupPresenter.hide()
        }
        if tier != .mirrorWindow {
            mirrorWindowPresenter.hide()
        }
    }
}

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
    private var contentView: NSHostingView<SimpleCaretPopupView>?
    private var fontSizeResolver = GhostFontSizeResolver()

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
        contentView.rootView = SimpleCaretPopupView(text: SimpleCaretPopupLayout.normalized(suggestion.visibleText))
        contentView.frame = NSRect(origin: .zero, size: layout.panelFrame.size)
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

    private func makeContentView(for panel: NSPanel) -> NSHostingView<SimpleCaretPopupView> {
        let view = NSHostingView(rootView: SimpleCaretPopupView(text: ""))
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 32)
        panel.contentView = view
        return view
    }
}

@MainActor
final class MultiSuggestionPopupPresenter: VisualInlineSuggestionPresenting {
    private var panel: NSPanel?
    private var contentView: NSHostingView<MultiSuggestionPopupView>?
    private var fontSizeResolver = GhostFontSizeResolver()

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
        contentView.rootView = MultiSuggestionPopupView(
            alternatives: suggestion.alternatives,
            selectedIndex: suggestion.selectedAlternativeIndex
        )
        contentView.frame = NSRect(origin: .zero, size: layout.panelFrame.size)
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

    private func makeContentView(for panel: NSPanel) -> NSHostingView<MultiSuggestionPopupView> {
        let view = NSHostingView(rootView: MultiSuggestionPopupView(alternatives: [], selectedIndex: 0))
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

        contentView.update(
            layout: ghostLayout,
            font: font,
            textColor: ghostTextColor(),
            textDirection: textDirection
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

    func show(_ suggestion: Suggestion, for context: TextContext) {
        update(suggestion, for: context)
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let contentView = contentView ?? makeContentView(for: panel)
        self.contentView = contentView

        contentView.update(text: suggestion.visibleText, appName: context.app.displayName)
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

struct InlinePreviewLayout: Equatable {
    let origin: CGPoint
    let size: NSSize
    let source: InlinePreviewLayoutSource
    let inputFrame: NSRect?
    let ghostTextLayout: InlineGhostTextLayout?

    init(
        origin: CGPoint,
        size: NSSize,
        source: InlinePreviewLayoutSource,
        inputFrame: NSRect? = nil,
        ghostTextLayout: InlineGhostTextLayout? = nil
    ) {
        self.origin = origin
        self.size = size
        self.source = source
        self.inputFrame = inputFrame
        self.ghostTextLayout = ghostTextLayout
    }
}

enum InlinePreviewLayoutSource: String, Equatable {
    case exactAX
    case textBoxEstimate
}

struct InlineGhostTextLayout: Equatable {
    struct Line: Equatable {
        let text: String
        let indent: CGFloat
        let width: CGFloat
    }

    enum PlacementReason: String, Equatable {
        case sameLine
        case wrappedLine
        case rightToLeft
        case clampedToVisibleFrame
    }

    let panelFrame: NSRect
    let lines: [Line]
    let lineHeight: CGFloat
    let keycapHintFrame: NSRect?
    let placementReason: PlacementReason

    static func resolve(
        text: String,
        font: NSFont,
        textDirection: TextDirection,
        anchorFrame: NSRect,
        inputFrame: NSRect?,
        visibleFrame: NSRect,
        observedCharacterWidth: CGFloat?,
        geometryQuality: CaretGeometryQuality,
        maxPanelWidth: CGFloat = 520
    ) -> InlineGhostTextLayout {
        let normalizedText = normalized(text)
        let lineHeight = max(16, ceil(font.ascender - font.descender + font.leading + 2))
        let keycapWidth = max(CGFloat(28), min(CGFloat(44), (observedCharacterWidth ?? font.pointSize * 0.55) * 5))
        let keycapGap: CGFloat = geometryQuality == .screenOCR ? 8 : 6
        let edgePadding: CGFloat = 4
        let minimumLineWidth = max(CGFloat(48), font.pointSize * 4)
        let sameLineAvailable: CGFloat
        switch textDirection {
        case .leftToRight:
            sameLineAvailable = visibleFrame.maxX - anchorFrame.minX
        case .rightToLeft:
            sameLineAvailable = anchorFrame.maxX - visibleFrame.minX
        }

        let shouldUseWrappedLine = textDirection == .leftToRight
            && sameLineAvailable < minimumLineWidth
        let rawPanelWidth = min(maxPanelWidth, max(minimumLineWidth, sameLineAvailable - edgePadding))
        let fallbackLineWidth = min(
            maxPanelWidth,
            max(
                minimumLineWidth,
                (inputFrame ?? visibleFrame).width - edgePadding * 2
            )
        )
        let panelWidth = shouldUseWrappedLine ? fallbackLineWidth : rawPanelWidth
        let wrappedLines = wrappedTextLines(
            normalizedText,
            font: font,
            maxLineWidth: panelWidth
        )
        let longestLineWidth = wrappedLines.map(\.width).max() ?? minimumLineWidth
        let measuredWidth = min(
            panelWidth,
            max(minimumLineWidth, longestLineWidth + keycapWidth + keycapGap)
        )
        let lines = linesWithIndent(
            wrappedLines,
            panelWidth: measuredWidth,
            direction: textDirection
        )
        let panelHeight = max(lineHeight, lineHeight * CGFloat(max(1, lines.count)))

        let desiredOrigin: CGPoint
        let reason: PlacementReason
        switch textDirection {
        case .leftToRight where shouldUseWrappedLine:
            let x = min(
                max((inputFrame?.minX ?? visibleFrame.minX) + edgePadding, visibleFrame.minX),
                visibleFrame.maxX - measuredWidth
            )
            desiredOrigin = CGPoint(x: x, y: anchorFrame.minY - panelHeight - 2)
            reason = .wrappedLine
        case .leftToRight:
            desiredOrigin = CGPoint(x: anchorFrame.minX, y: anchorFrame.minY)
            reason = lines.count > 1 ? .wrappedLine : .sameLine
        case .rightToLeft:
            desiredOrigin = CGPoint(x: anchorFrame.maxX - measuredWidth, y: anchorFrame.minY)
            reason = .rightToLeft
        }

        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - measuredWidth)),
            y: min(max(desiredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelHeight))
        )
        let placementReason: PlacementReason = clampedOrigin == desiredOrigin ? reason : .clampedToVisibleFrame
        let panelFrame = NSRect(
            x: clampedOrigin.x,
            y: clampedOrigin.y,
            width: measuredWidth,
            height: panelHeight
        )
        let keycapHintFrame = keycapFrame(
            lines: lines,
            panelFrame: panelFrame,
            lineHeight: lineHeight,
            keycapWidth: keycapWidth,
            keycapGap: keycapGap,
            direction: textDirection
        )

        return InlineGhostTextLayout(
            panelFrame: panelFrame,
            lines: lines,
            lineHeight: lineHeight,
            keycapHintFrame: keycapHintFrame,
            placementReason: placementReason
        )
    }

    private static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func wrappedTextLines(
        _ text: String,
        font: NSFont,
        maxLineWidth: CGFloat
    ) -> [(text: String, width: CGFloat)] {
        guard !text.isEmpty else {
            return [("", 1)]
        }

        var lines: [(text: String, width: CGFloat)] = []
        var current = ""
        var currentWidth: CGFloat = 0
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            let candidateWidth = measuredWidth(candidate, font: font)
            if !current.isEmpty, candidateWidth > maxLineWidth {
                lines.append((current, currentWidth))
                current = word
                currentWidth = min(measuredWidth(word, font: font), maxLineWidth)
            } else {
                current = candidate
                currentWidth = min(candidateWidth, maxLineWidth)
            }
        }

        if !current.isEmpty {
            lines.append((current, currentWidth))
        }
        return lines
    }

    private static func linesWithIndent(
        _ lines: [(text: String, width: CGFloat)],
        panelWidth: CGFloat,
        direction: TextDirection
    ) -> [Line] {
        lines.map { line in
            let indent: CGFloat
            switch direction {
            case .leftToRight:
                indent = 0
            case .rightToLeft:
                indent = max(0, panelWidth - line.width)
            }
            return Line(text: line.text, indent: indent, width: line.width)
        }
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width + 2)
    }

    private static func keycapFrame(
        lines: [Line],
        panelFrame: NSRect,
        lineHeight: CGFloat,
        keycapWidth: CGFloat,
        keycapGap: CGFloat,
        direction: TextDirection
    ) -> NSRect? {
        guard let lastLine = lines.last else {
            return nil
        }

        let lineIndex = CGFloat(max(0, lines.count - 1))
        let height = max(CGFloat(12), lineHeight - 4)
        let y = panelFrame.minY + lineIndex * lineHeight + 2
        switch direction {
        case .leftToRight:
            let x = panelFrame.minX + lastLine.indent + lastLine.width + keycapGap
            guard x + keycapWidth <= panelFrame.maxX else {
                return nil
            }
            return NSRect(x: x, y: y, width: keycapWidth, height: height)
        case .rightToLeft:
            let x = panelFrame.minX + lastLine.indent - keycapGap - keycapWidth
            guard x >= panelFrame.minX else {
                return nil
            }
            return NSRect(x: x, y: y, width: keycapWidth, height: height)
        }
    }
}

struct SimpleCaretPopupLayout: Equatable {
    enum PlacementReason: String, Equatable {
        case caret
        case focusedElement
        case clampedToVisibleFrame
    }

    let panelFrame: NSRect
    let anchorFrame: NSRect
    let placementReason: PlacementReason

    static func resolve(
        text: String,
        context: TextContext,
        font: NSFont,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        maxPanelWidth: CGFloat = 360
    ) -> SimpleCaretPopupLayout? {
        guard context.selectedRange?.length == 0 else {
            return nil
        }

        let normalizedText = normalized(text)
        guard !normalizedText.isEmpty,
              screenFrame.isFiniteAndNonEmpty,
              visibleFrame.isFiniteAndNonEmpty else {
            return nil
        }

        let validation = OverlayGeometryValidator(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames
        ).validate(context: context)

        let anchor: NSRect
        let reason: PlacementReason
        if let caretRect = validation.caretRect
            ?? validation.previousGlyphRect
            ?? validation.nextGlyphRect {
            anchor = caretRect
            reason = .caret
        } else if let focusedElementRect = validation.focusedElementRect {
            anchor = focusedElementRect
            reason = .focusedElement
        } else {
            return nil
        }

        let measured = measuredSize(for: normalizedText, font: font)
        let panelWidth = min(maxPanelWidth, max(CGFloat(92), measured.width + 60))
        let panelHeight = max(CGFloat(28), measured.height + 12)
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let desiredX: CGFloat
        switch textDirection {
        case .leftToRight:
            desiredX = anchor.minX
        case .rightToLeft:
            desiredX = anchor.maxX - panelWidth
        }

        let belowY = anchor.minY - panelHeight - 6
        let desiredY = belowY >= visibleFrame.minY
            ? belowY
            : anchor.maxY + 6
        let desiredOrigin = CGPoint(x: desiredX, y: desiredY)
        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelWidth)),
            y: min(max(desiredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelHeight))
        )
        let placementReason = clampedOrigin == desiredOrigin ? reason : .clampedToVisibleFrame

        return SimpleCaretPopupLayout(
            panelFrame: NSRect(
                x: clampedOrigin.x,
                y: clampedOrigin.y,
                width: panelWidth,
                height: panelHeight
            ),
            anchorFrame: anchor,
            placementReason: placementReason
        )
    }

    static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func measuredSize(for text: String, font: NSFont) -> NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
}

struct MultiSuggestionPopupLayout: Equatable {
    enum PlacementReason: String, Equatable {
        case caret
        case focusedElement
        case clampedToVisibleFrame
    }

    let panelFrame: NSRect
    let anchorFrame: NSRect
    let placementReason: PlacementReason

    static func resolve(
        suggestion: Suggestion,
        context: TextContext,
        font: NSFont,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        maxPanelWidth: CGFloat = 420
    ) -> MultiSuggestionPopupLayout? {
        guard suggestion.hasMultipleAlternatives,
              context.selectedRange?.length == 0,
              screenFrame.isFiniteAndNonEmpty,
              visibleFrame.isFiniteAndNonEmpty else {
            return nil
        }

        let validation = OverlayGeometryValidator(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames
        ).validate(context: context)

        let anchor: NSRect
        let reason: PlacementReason
        if let caretRect = validation.caretRect
            ?? validation.previousGlyphRect
            ?? validation.nextGlyphRect {
            anchor = caretRect
            reason = .caret
        } else if let focusedElementRect = validation.focusedElementRect {
            anchor = focusedElementRect
            reason = .focusedElement
        } else {
            return nil
        }

        let longest = suggestion.alternatives
            .map { SimpleCaretPopupLayout.normalized($0.visibleText) }
            .max { lhs, rhs in measuredWidth(lhs, font: font) < measuredWidth(rhs, font: font) } ?? ""
        guard !longest.isEmpty else {
            return nil
        }

        let panelWidth = min(maxPanelWidth, max(CGFloat(220), measuredWidth(longest, font: font) + 62))
        let rowCount = min(3, max(1, suggestion.alternatives.count))
        let panelHeight = CGFloat(rowCount * 30 + 12)
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let desiredX: CGFloat
        switch textDirection {
        case .leftToRight:
            desiredX = anchor.minX
        case .rightToLeft:
            desiredX = anchor.maxX - panelWidth
        }

        let belowY = anchor.minY - panelHeight - 6
        let desiredY = belowY >= visibleFrame.minY
            ? belowY
            : anchor.maxY + 6
        let desiredOrigin = CGPoint(x: desiredX, y: desiredY)
        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelWidth)),
            y: min(max(desiredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelHeight))
        )
        let placementReason = clampedOrigin == desiredOrigin ? reason : .clampedToVisibleFrame

        return MultiSuggestionPopupLayout(
            panelFrame: NSRect(x: clampedOrigin.x, y: clampedOrigin.y, width: panelWidth, height: panelHeight),
            anchorFrame: anchor,
            placementReason: placementReason
        )
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct InlinePreviewResolution {
    let layout: InlinePreviewLayout?
    let rejectionReason: String?

    init(layout: InlinePreviewLayout) {
        self.layout = layout
        self.rejectionReason = nil
    }

    init(rejectionReason: String) {
        self.layout = nil
        self.rejectionReason = rejectionReason
    }
}

enum InlinePreviewGeometry {
    private static let caretGap: CGFloat = 1
    private static let minimumUsefulWidth: CGFloat = 24
    private static let screenTolerance: CGFloat = 12

    static func layout(
        context: TextContext,
        contentSize: NSSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        allowsLineWrapPlacement: Bool = false
    ) -> InlinePreviewLayout? {
        resolve(
            context: context,
            contentSize: contentSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames,
            allowsLineWrapPlacement: allowsLineWrapPlacement
        ).layout
    }

    static func resolve(
        context: TextContext,
        contentSize: NSSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        allowsLineWrapPlacement: Bool = false
    ) -> InlinePreviewResolution {
        guard isCollapsedSelection(context.selectedRange) else {
            return InlinePreviewResolution(rejectionReason: "selection-not-collapsed")
        }

        guard screenFrame.isFiniteAndNonEmpty, visibleFrame.isFiniteAndNonEmpty else {
            return InlinePreviewResolution(rejectionReason: "invalid-screen")
        }

        let validation = OverlayGeometryValidator(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames
        ).validate(context: context)
        let focusedElementRect = validation.focusedElementRect
        let caretRect = validation.caretRect
        let previousGlyphRect = validation.previousGlyphRect
        let nextGlyphRect = validation.nextGlyphRect

        guard caretRect != nil || previousGlyphRect != nil || nextGlyphRect != nil else {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "missing-valid-text-metrics"
            )
        }

        if isWebLikeApp(context.app.bundleID),
           focusedElementRect != nil,
           previousGlyphRect == nil,
           !hasReliableFineCaret(caretRect) {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "web-missing-glyph-reference"
            )
        }

        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        guard let insertionX = insertionPointX(
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect,
            textDirection: textDirection
        ) else {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "missing-insertion-x"
            )
        }

        let x: CGFloat
        let availableWidth: CGFloat
        switch textDirection {
        case .leftToRight:
            x = insertionX + caretGap
            guard x >= visibleFrame.minX - screenTolerance,
                  x <= visibleFrame.maxX + screenTolerance else {
                return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
            }
            let rightSideWidth = visibleFrame.maxX - x
            guard rightSideWidth >= minimumUsefulWidth || allowsLineWrapPlacement else {
                return InlinePreviewResolution(rejectionReason: "insufficient-right-side-space")
            }
            availableWidth = max(rightSideWidth, minimumUsefulWidth)
        case .rightToLeft:
            let rightEdge = insertionX - caretGap
            guard rightEdge >= visibleFrame.minX - screenTolerance,
                  rightEdge <= visibleFrame.maxX + screenTolerance else {
                return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
            }
            let leftSideWidth = rightEdge - visibleFrame.minX
            guard leftSideWidth >= minimumUsefulWidth || allowsLineWrapPlacement else {
                return InlinePreviewResolution(rejectionReason: "insufficient-left-side-space")
            }
            availableWidth = max(leftSideWidth, minimumUsefulWidth)
            let width = min(max(contentSize.width, minimumUsefulWidth), availableWidth)
            x = rightEdge - width
        }

        guard x >= visibleFrame.minX - screenTolerance,
              x <= visibleFrame.maxX + screenTolerance else {
            return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
        }

        guard let referenceRect = lineReferenceRect(
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect
        ) else {
            return InlinePreviewResolution(rejectionReason: "missing-line-reference")
        }

        let height = max(1, max(contentSize.height, referenceRect.height))
        let y = referenceRect.maxY - height
        let size = NSSize(width: min(max(contentSize.width, minimumUsefulWidth), availableWidth), height: height)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard visibleFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            return InlinePreviewResolution(rejectionReason: "panel-outside-visible-frame")
        }

        return InlinePreviewLayout(
            origin: CGPoint(x: x, y: y),
            size: size,
            source: .exactAX,
            inputFrame: focusedElementRect
        )
        .resolution
    }

    static func referenceHeight(for context: TextContext) -> CGFloat {
        [
            context.previousGlyphRect,
            context.lineReferenceRect,
            context.nextGlyphRect,
            context.caretRect
        ]
        .compactMap { $0?.height }
        .first { $0.isFinite && $0 > 0 }
        ?? 14
    }

    static func fontSize(for context: TextContext) -> CGFloat {
        max(12, min(18, referenceHeight(for: context)))
    }

    private static func isCollapsedSelection(_ selectedRange: NSRange?) -> Bool {
        selectedRange?.length == 0
    }

    private static func insertionPointX(
        caretRect: CGRect?,
        previousGlyphRect: CGRect?,
        textDirection: TextDirection
    ) -> CGFloat? {
        if textDirection == .rightToLeft {
            if let caretRect, OverlayGeometry.isFineCaret(caretRect) {
                return caretRect.minX
            }

            if let previousGlyphRect {
                return previousGlyphRect.minX
            }

            if let caretRect {
                return caretRect.minX
            }

            return nil
        }

        if let caretRect, OverlayGeometry.isFineCaret(caretRect) {
            return caretRect.maxX
        }

        if let previousGlyphRect {
            return previousGlyphRect.maxX
        }

        if let caretRect {
            return caretRect.minX
        }

        return nil
    }

    private static func hasReliableFineCaret(_ caretRect: CGRect?) -> Bool {
        guard let caretRect else {
            return false
        }
        return OverlayGeometry.isFineCaret(caretRect)
    }

    private static func lineReferenceRect(
        caretRect: CGRect?,
        previousGlyphRect: CGRect?,
        nextGlyphRect: CGRect?
    ) -> CGRect? {
        if let previousGlyphRect {
            return previousGlyphRect
        }
        if let nextGlyphRect {
            return nextGlyphRect
        }
        return caretRect
    }

    private static func estimatedTextBoxLayout(
        context: TextContext,
        focusedElementRect: CGRect?,
        contentSize: NSSize,
        visibleFrame: CGRect,
        fallbackReason: String
    ) -> InlinePreviewResolution {
        guard let focusedElementRect else {
            return InlinePreviewResolution(rejectionReason: fallbackReason)
        }

        let horizontalPadding = estimatedHorizontalPadding(for: context)
        let visibleFocus = focusedElementRect.intersection(visibleFrame)
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        guard visibleFocus.isFiniteAndNonEmpty,
              visibleFocus.width >= minimumUsefulWidth + horizontalPadding * 2,
              visibleFocus.height >= 12 else {
            return InlinePreviewResolution(rejectionReason: "invalid-focused-element-fallback")
        }

        let fontSize = estimatedFontSize(for: focusedElementRect, context: context)
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = estimatedLineHeight(for: font)

        let leftLimit = visibleFocus.minX + horizontalPadding
        let rightLimit = visibleFocus.maxX - 2
        let maxXWithUsefulSpace = rightLimit - minimumUsefulWidth
        guard maxXWithUsefulSpace >= leftLimit else {
            return InlinePreviewResolution(rejectionReason: "insufficient-focused-element-space")
        }

        let maxTextLineWidth = max(1, rightLimit - leftLimit - caretGap)
        let lineEstimate = estimatedVisibleLine(
            in: context.textBeforeCursor,
            font: font,
            maxLineWidth: maxTextLineWidth
        )
        let measuredLineWidth = lineEstimate.width
        let x: CGFloat
        let availableWidth: CGFloat
        let estimatedAnchorX: CGFloat
        switch textDirection {
        case .leftToRight:
            estimatedAnchorX = leftLimit + measuredLineWidth + caretGap
            x = min(max(estimatedAnchorX, leftLimit), maxXWithUsefulSpace)
            availableWidth = rightLimit - x
            guard availableWidth >= minimumUsefulWidth else {
                return InlinePreviewResolution(rejectionReason: "insufficient-right-side-space")
            }
        case .rightToLeft:
            estimatedAnchorX = rightLimit - measuredLineWidth - caretGap
            let minimumRightEdge = leftLimit + minimumUsefulWidth
            let rightEdge = min(max(estimatedAnchorX, minimumRightEdge), rightLimit)
            availableWidth = rightEdge - leftLimit
            guard availableWidth >= minimumUsefulWidth else {
                return InlinePreviewResolution(rejectionReason: "insufficient-left-side-space")
            }
            let width = min(max(contentSize.width, minimumUsefulWidth), availableWidth)
            x = rightEdge - width
        }

        let height = max(1, max(contentSize.height, lineHeight))
        let verticalPadding = estimatedVerticalPadding(for: visibleFocus, context: context)
        let visibleLineCapacity = max(1, Int(floor((visibleFocus.height - verticalPadding * 2) / lineHeight)))
        let desiredLineIndex = min(lineEstimate.lineIndex, max(0, visibleLineCapacity - 1))
        let topY = visibleFocus.maxY - verticalPadding - (CGFloat(desiredLineIndex) * lineHeight)
        let minY = visibleFocus.minY + 2
        let maxY = visibleFocus.maxY - height - 2
        guard maxY >= minY else {
            return InlinePreviewResolution(rejectionReason: "insufficient-focused-element-height")
        }
        let y = min(
            max(topY - height, minY),
            maxY
        )

        let size = NSSize(width: min(max(contentSize.width, minimumUsefulWidth), availableWidth), height: height)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard visibleFocus.insetBy(dx: -screenTolerance, dy: -screenTolerance).contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            return InlinePreviewResolution(rejectionReason: "estimated-panel-outside-focused-element")
        }

        GeometryDebug.log("metric=text-box-estimate reason=\(fallbackReason) focused=\(focusedElementRect) lineIndex=\(lineEstimate.lineIndex) lineWidth=\(measuredLineWidth) estimatedAnchorX=\(estimatedAnchorX) direction=\(textDirection) panel=\(frame)")
        return InlinePreviewLayout(
            origin: CGPoint(x: x, y: y),
            size: size,
            source: .textBoxEstimate,
            inputFrame: focusedElementRect
        ).resolution
    }

    private static func estimatedFontSize(for focusedElementRect: CGRect, context: TextContext) -> CGFloat {
        if isWebLikeApp(context.app.bundleID) {
            return 14
        }
        return min(17, max(13, focusedElementRect.height * 0.42))
    }

    private static func estimatedHorizontalPadding(for context: TextContext) -> CGFloat {
        isWebLikeApp(context.app.bundleID) ? 4 : 8
    }

    private static func estimatedLineHeight(for font: NSFont) -> CGFloat {
        max(16, ceil(font.ascender - font.descender + font.leading + 2))
    }

    private static func estimatedVerticalPadding(for visibleFocus: CGRect, context: TextContext) -> CGFloat {
        if isWebLikeApp(context.app.bundleID) {
            return min(8, max(5, visibleFocus.height * 0.12))
        }
        return max(CGFloat(4), min(CGFloat(10), visibleFocus.height * 0.16))
    }

    private static func isWebLikeApp(_ bundleID: String) -> Bool {
        [
            "com.openai.codex",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.todesktop.230313mzl4w4u92"
        ].contains(bundleID)
    }

    private static func estimatedVisibleLine(in text: String, font: NSFont, maxLineWidth: CGFloat) -> (width: CGFloat, lineIndex: Int) {
        let lineText = lastLine(in: text)
        var currentLine = ""
        var currentWidth: CGFloat = 0
        var visualLineCount = 1
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        for character in lineText {
            let candidate = currentLine + String(character)
            let candidateWidth = ceil((candidate as NSString).size(withAttributes: attributes).width)
            if !currentLine.isEmpty, candidateWidth > maxLineWidth {
                visualLineCount += 1
                currentLine = String(character)
                currentWidth = ceil((currentLine as NSString).size(withAttributes: attributes).width)
            } else {
                currentLine = candidate
                currentWidth = candidateWidth
            }
        }

        return (width: min(currentWidth, maxLineWidth), lineIndex: visualLineCount - 1)
    }

    private static func lastLine(in text: String) -> String {
        if let lastNewline = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(text[text.index(after: lastNewline)...])
        }
        return text
    }

}

struct OverlayGeometryValidation: Equatable {
    let focusedElementRect: CGRect?
    let caretRect: CGRect?
    let previousGlyphRect: CGRect?
    let nextGlyphRect: CGRect?
    let lineReferenceRect: CGRect?
}

struct OverlayGeometryValidator {
    private let screenFrame: CGRect
    private let visibleFrame: CGRect
    private let screenFrames: [CGRect]
    private let focusedElementTolerance: CGFloat
    private let screenTolerance: CGFloat

    init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        focusedElementTolerance: CGFloat = 12,
        screenTolerance: CGFloat = 12
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.screenFrames = screenFrames.isEmpty ? [screenFrame] : screenFrames
        self.focusedElementTolerance = focusedElementTolerance
        self.screenTolerance = screenTolerance
    }

    func validate(context: TextContext) -> OverlayGeometryValidation {
        let focusedElementRect = validatedElementRect(context.focusedElementRect)
        let caretRect = validatedMetricRect(
            context.caretRect,
            name: "caret",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        let previousGlyphRect = validatedMetricRect(
            context.previousGlyphRect ?? context.lineReferenceRect,
            name: "previous-glyph",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        let nextGlyphRect = validatedMetricRect(
            context.nextGlyphRect,
            name: "next-glyph",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        let lineReferenceRect = validatedMetricRect(
            context.lineReferenceRect,
            name: "line-reference",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        return OverlayGeometryValidation(
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect
        )
    }

    private func validatedElementRect(_ rawRect: CGRect?) -> CGRect? {
        guard let rawRect,
              rawRect.isFiniteAndNonEmpty,
              rawRect.width <= screenFrame.width * 1.2,
              rawRect.height <= screenFrame.height * 1.2 else {
            return nil
        }

        guard !isSuspiciousZeroOrigin(rawRect) else {
            GeometryDebug.log("overlay-geometry rejected-zero-origin metric=focused-element raw=\(rawRect)")
            return nil
        }

        guard let converted = convertedRect(rawRect, name: "focused-element") else {
            return nil
        }
        GeometryDebug.log("overlay-geometry accepted metric=focused-element converted=\(converted)")
        return converted
    }

    private func validatedMetricRect(
        _ rawRect: CGRect?,
        name: String,
        quality: CaretGeometryQuality,
        selectedRange: NSRange?,
        focusedElementRect: CGRect?
    ) -> CGRect? {
        guard let rawRect else {
            return nil
        }

        guard rawRect.isFiniteAndNonEmpty || isCollapsedCaretMetric(rawRect, metricName: name) else {
            GeometryDebug.log("overlay-geometry rejected-empty metric=\(name) raw=\(rawRect)")
            return nil
        }

        guard !isSuspiciousZeroOrigin(rawRect) else {
            GeometryDebug.log("overlay-geometry rejected-zero-origin metric=\(name) raw=\(rawRect)")
            return nil
        }

        let normalizedRawRect = normalizedMetricRect(
            rawRect,
            metricName: name,
            quality: quality,
            selectedRange: selectedRange
        )

        guard metricWithinQualityCaps(normalizedRawRect, metricName: name, quality: quality) else {
            GeometryDebug.log("overlay-geometry rejected-absurd-size metric=\(name) raw=\(rawRect) normalized=\(normalizedRawRect) quality=\(quality.rawValue)")
            return nil
        }

        guard let converted = convertedRect(normalizedRawRect, name: name) else {
            return nil
        }

        if let focusedElementRect,
           shouldRequireFocusProximity(metricName: name, quality: quality) {
            let expandedFocus = focusedElementRect.insetBy(dx: -focusedElementTolerance, dy: -focusedElementTolerance)
            guard expandedFocus.intersects(converted) || expandedFocus.contains(CGPoint(x: converted.midX, y: converted.midY)) else {
                GeometryDebug.log("overlay-geometry rejected-far-from-field metric=\(name) raw=\(rawRect) converted=\(converted) focused=\(focusedElementRect) quality=\(quality.rawValue)")
                return nil
            }
        }

        if normalizedRawRect != rawRect {
            GeometryDebug.log("overlay-geometry normalized metric=\(name) raw=\(rawRect) normalized=\(normalizedRawRect) converted=\(converted) quality=\(quality.rawValue)")
        } else {
            GeometryDebug.log("overlay-geometry accepted metric=\(name) converted=\(converted) quality=\(quality.rawValue)")
        }
        return converted
    }

    private func convertedRect(_ rawRect: CGRect, name: String) -> CGRect? {
        for candidate in rawRectCandidates(rawRect) {
            let converted = OverlayGeometry.appKitRect(accessibilityRect: candidate.rect, screenFrame: screenFrame)
            guard converted.isFiniteAndNonEmpty else {
                continue
            }
            if intersectsAnyScreen(converted) {
                if let reason = candidate.reason {
                    GeometryDebug.log("overlay-geometry normalized metric=\(name) reason=\(reason) raw=\(rawRect) normalized=\(candidate.rect) converted=\(converted)")
                }
                return converted
            }
        }

        let converted = OverlayGeometry.appKitRect(accessibilityRect: rawRect, screenFrame: screenFrame)
        GeometryDebug.log("overlay-geometry rejected-outside-screen metric=\(name) raw=\(rawRect) converted=\(converted)")
        return nil
    }

    private func rawRectCandidates(_ rawRect: CGRect) -> [(rect: CGRect, reason: String?)] {
        var candidates: [(rect: CGRect, reason: String?)] = [(rawRect, nil)]
        for scale in [CGFloat(2), CGFloat(3)] {
            let scaled = CGRect(
                x: rawRect.minX / scale,
                y: rawRect.minY / scale,
                width: rawRect.width / scale,
                height: rawRect.height / scale
            )
            candidates.append((scaled, "physical-to-points-\(Int(scale))x"))
        }
        return candidates
    }

    private func intersectsAnyScreen(_ rect: CGRect) -> Bool {
        let expanded = rect.insetBy(dx: -screenTolerance, dy: -screenTolerance)
        return screenFrames.contains { screenFrame in
            screenFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).intersects(expanded)
        } || visibleFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).intersects(expanded)
    }

    private func isSuspiciousZeroOrigin(_ rect: CGRect) -> Bool {
        abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5
    }

    private func isCollapsedCaretMetric(_ rect: CGRect, metricName: String) -> Bool {
        guard metricName == "caret" || metricName == "previous-glyph" else {
            return false
        }
        return rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width == 0
            && rect.height > 0
    }

    private func normalizedMetricRect(
        _ rect: CGRect,
        metricName: String,
        quality: CaretGeometryQuality,
        selectedRange: NSRange?
    ) -> CGRect {
        if isCollapsedCaretMetric(rect, metricName: metricName) {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }

        if metricName == "caret",
           selectedRange?.length == 0,
           rect.width > max(CGFloat(4), rect.height * 0.35),
           quality != .elementFrame,
           quality != .unavailable {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }

        return rect
    }

    private func metricWithinQualityCaps(
        _ rect: CGRect,
        metricName: String,
        quality: CaretGeometryQuality
    ) -> Bool {
        let maximumHeight: CGFloat
        switch quality {
        case .directCaret, .glyph, .lineMetric, .screenOCR:
            maximumHeight = max(120, screenFrame.height * 0.25)
        case .elementFrame, .unavailable:
            maximumHeight = max(80, screenFrame.height * 0.12)
        }

        let maximumWidth = metricName == "caret"
            ? max(CGFloat(24), screenFrame.width * 0.05)
            : screenFrame.width
        return rect.width <= maximumWidth && rect.height <= maximumHeight
    }

    private func shouldRequireFocusProximity(metricName: String, quality: CaretGeometryQuality) -> Bool {
        guard metricName != "focused-element" else {
            return false
        }
        switch quality {
        case .screenOCR:
            return false
        case .directCaret, .glyph, .lineMetric, .elementFrame, .unavailable:
            return true
        }
    }
}

enum OverlayGeometry {
    static func appKitPoint(accessibilityPoint: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: accessibilityPoint.x, y: screenFrame.maxY - accessibilityPoint.y)
    }

    static func appKitRect(accessibilityRect rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(containingAccessibilityRect rect: CGRect) -> NSScreen {
        let mainScreenFrame = NSScreen.screens.first?.frame ?? .zero
        return NSScreen.screens.first { screen in
            let point = appKitPoint(
                accessibilityPoint: CGPoint(x: rect.midX, y: rect.midY),
                screenFrame: mainScreenFrame
            )
            return screen.frame.contains(point)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func insertionPointX(for caretRect: CGRect) -> CGFloat {
        isFineCaret(caretRect) ? caretRect.maxX : caretRect.minX
    }

    static func isFineCaret(_ caretRect: CGRect) -> Bool {
        caretRect.width <= max(CGFloat(4), caretRect.height * 0.35)
    }
}

private extension InlinePreviewLayout {
    var resolution: InlinePreviewResolution {
        InlinePreviewResolution(layout: self)
    }
}

private extension CGRect {
    var isFiniteAndNonEmpty: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && width > 0
            && height > 0
    }
}

extension TextContext {
    var geometryDebugDescription: String {
        [
            "selectedRange=\(String(describing: selectedRange))",
            "focusedElementRect=\(String(describing: focusedElementRect))",
            "caretRect=\(String(describing: caretRect))",
            "previousGlyphRect=\(String(describing: previousGlyphRect))",
            "nextGlyphRect=\(String(describing: nextGlyphRect))",
            "lineReferenceRect=\(String(describing: lineReferenceRect))",
            "caretGeometryQuality=\(caretGeometryQuality.rawValue)",
            "observedCharacterWidth=\(String(describing: observedCharacterWidth))"
        ].joined(separator: " ")
    }
}

private struct SimpleCaretPopupView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary.opacity(0.82))
            Text("Tab")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.13))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct MultiSuggestionPopupView: View {
    let alternatives: [SuggestionAlternative]
    let selectedIndex: Int

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(alternatives.prefix(3).enumerated()), id: \.offset) { index, alternative in
                HStack(spacing: 8) {
                    Text(SimpleCaretPopupLayout.normalized(alternative.visibleText))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(index == selectedIndex ? .primary : .secondary)
                    Spacer(minLength: 8)
                    if index == selectedIndex {
                        Text("Tab")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.secondary.opacity(0.13))
                            )
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private final class InlineGhostTextView: NSView {
    private var layout = InlineGhostTextLayout(
        panelFrame: .zero,
        lines: [],
        lineHeight: 16,
        keycapHintFrame: nil,
        placementReason: .sameLine
    )
    private var font = NSFont.systemFont(ofSize: 14)
    private var textColor = NSColor.tertiaryLabelColor
    private var textDirection = TextDirection.leftToRight

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    func update(
        layout: InlineGhostTextLayout,
        font: NSFont,
        textColor: NSColor,
        textDirection: TextDirection
    ) {
        self.layout = layout
        self.font = font
        self.textColor = textColor
        self.textDirection = textDirection
        frame = NSRect(origin: .zero, size: layout.panelFrame.size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        switch textDirection {
        case .leftToRight:
            paragraphStyle.alignment = .left
            paragraphStyle.baseWritingDirection = .leftToRight
        case .rightToLeft:
            paragraphStyle.alignment = .right
            paragraphStyle.baseWritingDirection = .rightToLeft
        }
        for (index, line) in layout.lines.enumerated() {
            let attributedText = NSAttributedString(
                string: line.text,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
            let drawRect = NSRect(
                x: bounds.minX + line.indent,
                y: bounds.minY + CGFloat(index) * layout.lineHeight,
                width: max(1, bounds.width - line.indent),
                height: layout.lineHeight
            )
            attributedText.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if let keycapFrame = layout.keycapHintFrame {
            drawKeycap(keycapFrame.offsetBy(dx: -layout.panelFrame.minX, dy: -layout.panelFrame.minY))
        }
    }

    private func drawKeycap(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        path.fill()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributedText = NSAttributedString(
            string: "Tab",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(9, font.pointSize - 3), weight: .medium),
                .foregroundColor: textColor.withAlphaComponent(0.8),
                .paragraphStyle: paragraphStyle
            ]
        )
        attributedText.draw(
            with: rect.insetBy(dx: 2, dy: 1),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }
}

private final class MirrorSuggestionOverlayContentView: NSView {
    private let backgroundView = NSVisualEffectView()
    private let appLabel = NSTextField(labelWithString: "")
    private let suggestionLabel = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 7
    private let spacing: CGFloat = 8
    private let maxWidth: CGFloat = 420
    private let minHeight: CGFloat = 33

    var preferredSize = NSSize(width: 120, height: 33)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()

        backgroundView.frame = bounds
        let bounds = bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        var x = bounds.minX

        let appSize = appLabel.intrinsicContentSize
        appLabel.frame = NSRect(x: x, y: bounds.minY, width: min(appSize.width, 110), height: bounds.height)
        x = appLabel.frame.maxX + spacing

        suggestionLabel.frame = NSRect(
            x: x,
            y: bounds.minY,
            width: max(bounds.maxX - x, 40),
            height: bounds.height
        )
    }

    func update(text: String, appName: String) {
        appLabel.stringValue = appName
        suggestionLabel.stringValue = text

        let appWidth = min(appLabel.intrinsicContentSize.width, 110) + spacing
        let suggestionWidth = min(suggestionLabel.intrinsicContentSize.width, maxWidth - appWidth - horizontalPadding * 2)
        let width = min(maxWidth, max(80, appWidth + suggestionWidth + horizontalPadding * 2))
        preferredSize = NSSize(width: width, height: minHeight)
        frame = NSRect(origin: .zero, size: preferredSize)
        needsLayout = true
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true

        appLabel.font = .systemFont(ofSize: 11)
        appLabel.textColor = .secondaryLabelColor
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.maximumNumberOfLines = 1

        suggestionLabel.font = .systemFont(ofSize: 15)
        suggestionLabel.textColor = .secondaryLabelColor
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.maximumNumberOfLines = 1

        addSubview(backgroundView)
        addSubview(appLabel)
        addSubview(suggestionLabel)
    }
}
