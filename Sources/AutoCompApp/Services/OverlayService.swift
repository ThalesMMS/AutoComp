import AppKit
import AutoCompCore
import OSLog

enum PreviewPresentationTier: Equatable {
    case nativeInline
    case visualInlineOverlay
    case mirrorWindow
    case disabled
}

enum GeometryDebug {
    private static let logger = Logger(subsystem: "com.autocomp.AutoComp", category: "geometry")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--geometry-debug")
            || ProcessInfo.processInfo.environment["AUTOCOMP_GEOMETRY_DEBUG"] == "1"
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }
        let resolvedMessage = message()
        logger.info("AutoCompGeometry \(resolvedMessage, privacy: .public)")
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
final class PreviewCoordinator: SuggestionPresenter {
    private let nativeInlinePresenter: NativeInlineSuggestionPresenting
    private let visualInlinePresenter: VisualInlineSuggestionPresenting
    private let mirrorWindowPresenter: SuggestionTierPresenting

    private(set) var activeTier: PreviewPresentationTier = .disabled

    init() {
        self.nativeInlinePresenter = UnavailableNativeInlinePresenter()
        self.visualInlinePresenter = VisualInlineOverlayPresenter()
        self.mirrorWindowPresenter = MirrorWindowSuggestionPresenter()
    }

    init(
        nativeInlinePresenter: NativeInlineSuggestionPresenting,
        visualInlinePresenter: VisualInlineSuggestionPresenting,
        mirrorWindowPresenter: SuggestionTierPresenting
    ) {
        self.nativeInlinePresenter = nativeInlinePresenter
        self.visualInlinePresenter = visualInlinePresenter
        self.mirrorWindowPresenter = mirrorWindowPresenter
    }

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        present(suggestion, for: context, mode: mode, isUpdate: false)
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        present(suggestion, for: context, mode: mode, isUpdate: true)
    }

    func hide() {
        activeTier = .disabled
        nativeInlinePresenter.hide()
        visualInlinePresenter.hide()
        mirrorWindowPresenter.hide()
    }

    func resolveTier(for suggestion: Suggestion, context: TextContext, mode: SuggestionDisplayMode) -> PreviewPresentationTier {
        guard mode != .disabled, !suggestion.visibleText.isEmpty else {
            return .disabled
        }

        switch mode {
        case .inline:
            if nativeInlinePresenter.canPresent(suggestion, for: context) {
                return .nativeInline
            }
            if visualInlinePresenter.canPresent(suggestion, for: context) {
                return .visualInlineOverlay
            }
            return .disabled
        case .mirrorWindow:
            return .mirrorWindow
        case .disabled:
            return .disabled
        }
    }

    private func present(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode, isUpdate: Bool) {
        let nextTier = resolveTier(for: suggestion, context: context, mode: mode)
        GeometryDebug.log("mode=\(mode.rawValue) resolvedTier=\(nextTier) app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
        let shouldUpdateExistingTier = isUpdate && activeTier == nextTier
        hidePresenters(except: nextTier)
        activeTier = nextTier

        switch nextTier {
        case .nativeInline:
            shouldUpdateExistingTier
                ? nativeInlinePresenter.update(suggestion, for: context)
                : nativeInlinePresenter.show(suggestion, for: context)
        case .visualInlineOverlay:
            shouldUpdateExistingTier
                ? visualInlinePresenter.update(suggestion, for: context)
                : visualInlinePresenter.show(suggestion, for: context)
        case .mirrorWindow:
            shouldUpdateExistingTier
                ? mirrorWindowPresenter.update(suggestion, for: context)
                : mirrorWindowPresenter.show(suggestion, for: context)
        case .disabled:
            break
        }
    }

    private func hidePresenters(except tier: PreviewPresentationTier) {
        if tier != .nativeInline {
            nativeInlinePresenter.hide()
        }
        if tier != .visualInlineOverlay {
            visualInlinePresenter.hide()
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
final class VisualInlineOverlayPresenter: VisualInlineSuggestionPresenting {
    private var panel: NSPanel?
    private var contentView: InlineGhostTextView?
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

        contentView.update(
            text: suggestion.visibleText,
            font: font(for: context),
            textColor: ghostTextColor(for: context)
        )
        panel.setFrame(NSRect(origin: layout.origin, size: layout.size), display: true)
        GeometryDebug.log("tier=visualInlineOverlay source=\(layout.source.rawValue) app=\(context.app.displayName) bundle=\(context.app.bundleID) panel=\(NSRect(origin: layout.origin, size: layout.size)) context=\(context.geometryDebugDescription)")
        panel.orderFrontRegardless()
    }

    func hide() {
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
        return InlinePreviewGeometry.resolve(
            context: context,
            contentSize: preferredSize(for: suggestion.visibleText, context: context),
            screenFrame: mainScreenFrame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func preferredSize(for text: String, context: TextContext) -> NSSize {
        let font = font(for: context)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        let referenceHeight = InlinePreviewGeometry.referenceHeight(for: context)
        return NSSize(
            width: min(maxWidth, max(1, ceil(measured.width + 2))),
            height: max(16, ceil(max(referenceHeight, measured.height)))
        )
    }

    private func font(for context: TextContext) -> NSFont {
        .systemFont(ofSize: InlinePreviewGeometry.fontSize(for: context))
    }

    private func ghostTextColor(for context: TextContext) -> NSColor {
        if context.domain?.contains("docs.google.com") == true {
            return NSColor(calibratedWhite: 0.22, alpha: 0.62)
        }

        return NSColor.tertiaryLabelColor.withAlphaComponent(0.72)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 18),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .init(Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        return panel
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .init(Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        return panel
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
}

enum InlinePreviewLayoutSource: String, Equatable {
    case exactAX
    case textBoxEstimate
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
    private static let focusedElementTolerance: CGFloat = 12
    private static let screenTolerance: CGFloat = 12

    static func layout(
        context: TextContext,
        contentSize: NSSize,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> InlinePreviewLayout? {
        resolve(
            context: context,
            contentSize: contentSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ).layout
    }

    static func resolve(
        context: TextContext,
        contentSize: NSSize,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> InlinePreviewResolution {
        guard isCollapsedSelection(context.selectedRange) else {
            return InlinePreviewResolution(rejectionReason: "selection-not-collapsed")
        }

        guard screenFrame.isFiniteAndNonEmpty, visibleFrame.isFiniteAndNonEmpty else {
            return InlinePreviewResolution(rejectionReason: "invalid-screen")
        }

        let focusedElementRect = validatedElementRect(
            context.focusedElementRect,
            screenFrame: screenFrame
        )
        let caretRect = validatedMetricRect(
            context.caretRect,
            screenFrame: screenFrame,
            focusedElementRect: focusedElementRect,
            name: "caret"
        )
        let previousGlyphRect = validatedMetricRect(
            context.previousGlyphRect ?? context.lineReferenceRect,
            screenFrame: screenFrame,
            focusedElementRect: focusedElementRect,
            name: "previous-glyph"
        )
        let nextGlyphRect = validatedMetricRect(
            context.nextGlyphRect,
            screenFrame: screenFrame,
            focusedElementRect: focusedElementRect,
            name: "next-glyph"
        )

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

        guard let insertionX = insertionPointX(caretRect: caretRect, previousGlyphRect: previousGlyphRect) else {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "missing-insertion-x"
            )
        }

        let x = insertionX + caretGap
        guard x >= visibleFrame.minX - screenTolerance,
              x <= visibleFrame.maxX + screenTolerance else {
            return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
        }

        let availableWidth = visibleFrame.maxX - x
        guard availableWidth >= minimumUsefulWidth else {
            return InlinePreviewResolution(rejectionReason: "insufficient-right-side-space")
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
            source: .exactAX
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

    private static func insertionPointX(caretRect: CGRect?, previousGlyphRect: CGRect?) -> CGFloat? {
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

    private static func validatedElementRect(_ rawRect: CGRect?, screenFrame: CGRect) -> CGRect? {
        guard let rawRect,
              rawRect.isFiniteAndNonEmpty,
              rawRect.width <= screenFrame.width * 1.2,
              rawRect.height <= screenFrame.height * 1.2 else {
            return nil
        }

        guard !(abs(rawRect.minX) < 0.5 && abs(rawRect.minY) < 0.5) else {
            GeometryDebug.log("metric=focused-element rejected reason=zero-origin raw=\(rawRect)")
            return nil
        }

        let converted = OverlayGeometry.appKitRect(accessibilityRect: rawRect, screenFrame: screenFrame)
        guard converted.isFiniteAndNonEmpty,
              screenFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).intersects(converted) else {
            return nil
        }
        return converted
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
        let estimatedX = leftLimit + measuredLineWidth + caretGap
        let x = min(max(estimatedX, leftLimit), maxXWithUsefulSpace)
        let availableWidth = rightLimit - x
        guard availableWidth >= minimumUsefulWidth else {
            return InlinePreviewResolution(rejectionReason: "insufficient-right-side-space")
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

        GeometryDebug.log("metric=text-box-estimate reason=\(fallbackReason) focused=\(focusedElementRect) lineIndex=\(lineEstimate.lineIndex) lineWidth=\(measuredLineWidth) estimatedX=\(estimatedX) panel=\(frame)")
        return InlinePreviewLayout(origin: CGPoint(x: x, y: y), size: size, source: .textBoxEstimate).resolution
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

    private static func validatedMetricRect(
        _ rawRect: CGRect?,
        screenFrame: CGRect,
        focusedElementRect: CGRect?,
        name: String
    ) -> CGRect? {
        guard let rawRect else {
            return nil
        }

        guard rawRect.isFiniteAndNonEmpty else {
            GeometryDebug.log("metric=\(name) rejected reason=non-finite-or-empty raw=\(rawRect)")
            return nil
        }

        guard !(abs(rawRect.minX) < 0.5 && abs(rawRect.minY) < 0.5) else {
            GeometryDebug.log("metric=\(name) rejected reason=zero-origin raw=\(rawRect)")
            return nil
        }

        guard rawRect.width <= screenFrame.width,
              rawRect.height <= max(120, screenFrame.height * 0.25) else {
            GeometryDebug.log("metric=\(name) rejected reason=absurd-size raw=\(rawRect)")
            return nil
        }

        let converted = OverlayGeometry.appKitRect(accessibilityRect: rawRect, screenFrame: screenFrame)
        guard converted.isFiniteAndNonEmpty,
              screenFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).intersects(converted) else {
            GeometryDebug.log("metric=\(name) rejected reason=outside-screen raw=\(rawRect) converted=\(converted)")
            return nil
        }

        if let focusedElementRect {
            let expandedFocus = focusedElementRect.insetBy(dx: -focusedElementTolerance, dy: -focusedElementTolerance)
            guard expandedFocus.intersects(converted) || expandedFocus.contains(CGPoint(x: converted.midX, y: converted.midY)) else {
                GeometryDebug.log("metric=\(name) rejected reason=outside-focused-element raw=\(rawRect) converted=\(converted) focused=\(focusedElementRect)")
                return nil
            }
        }

        return converted
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
            "lineReferenceRect=\(String(describing: lineReferenceRect))"
        ].joined(separator: " ")
    }
}

private final class InlineGhostTextView: NSView {
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 14)
    private var textColor = NSColor.tertiaryLabelColor

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

    func update(text: String, font: NSFont, textColor: NSColor) {
        self.text = text
        self.font = font
        self.textColor = textColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let textSize = attributedText.size()
        let drawRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(bounds.height, ceil(textSize.height) + 2)
        )
        attributedText.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
