import AppKit
import AutoCompCore
import SwiftUI

@MainActor
protocol FocusDebugOverlayPresenting: AnyObject {
    func show(context: TextContext, tier: PreviewPresentationTier)
    func hide()
}

struct FocusDebugOverlayOptions: Equatable {
    let arguments: [String]
    let environment: [String: String]

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.arguments = arguments
        self.environment = environment
    }

    var isEnabled: Bool {
        Self.isEnabled(arguments: arguments, environment: environment)
    }

    static func isEnabled(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        arguments.contains("--focus-debug-overlay")
            || arguments.contains("--debug-focus-overlay")
            || environment["AUTOCOMP_DEBUG_FOCUS_OVERLAY"] == "1"
    }
}

struct FocusDebugOverlayRectangle: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case caret
        case focusedElement = "focused-element"
        case previousGlyph = "previous-glyph"
        case nextGlyph = "next-glyph"
        case lineReference = "line-reference"
        case screenOCRRegion = "screenOCR-region"
    }

    let kind: Kind
    let rect: CGRect

    var id: String {
        "\(kind.rawValue)-\(rect.debugDescription)"
    }
}

struct FocusDebugOverlaySnapshot: Equatable {
    let panelFrame: CGRect
    let rectangles: [FocusDebugOverlayRectangle]
    let labels: [String]

    static func make(
        context: TextContext,
        tier: PreviewPresentationTier,
        visualContextSession: VisualContextSession?,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect]
    ) -> FocusDebugOverlaySnapshot? {
        let validation = OverlayGeometryValidator(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames
        ).validate(context: context)
        var rectangles: [FocusDebugOverlayRectangle] = []
        append(.focusedElement, validation.focusedElementRect, to: &rectangles)
        append(.caret, validation.caretRect, to: &rectangles)
        append(.previousGlyph, validation.previousGlyphRect, to: &rectangles)
        append(.nextGlyph, validation.nextGlyphRect, to: &rectangles)
        append(.lineReference, validation.lineReferenceRect, to: &rectangles)

        if context.captureSources.contains(.screenOCR),
           let screenOCRRegion = validation.focusedElementRect {
            append(.screenOCRRegion, screenOCRRegion, to: &rectangles)
        }

        guard !rectangles.isEmpty else {
            return nil
        }

        return FocusDebugOverlaySnapshot(
            panelFrame: screenFrame,
            rectangles: rectangles,
            labels: labels(
                context: context,
                tier: tier,
                visualContextSession: visualContextSession
            )
        )
    }

    private static func append(
        _ kind: FocusDebugOverlayRectangle.Kind,
        _ rect: CGRect?,
        to rectangles: inout [FocusDebugOverlayRectangle]
    ) {
        guard let rect else {
            return
        }
        rectangles.append(FocusDebugOverlayRectangle(kind: kind, rect: rect))
    }

    private static func labels(
        context: TextContext,
        tier: PreviewPresentationTier,
        visualContextSession: VisualContextSession?
    ) -> [String] {
        [
            "source=\(sourceLabel(context.captureSources))",
            "quality=\(context.caretGeometryQuality.rawValue)",
            "tier=\(tier.debugLabel)",
            "stable=\(stableIdentityLabel(context.stableFieldIdentity))",
            "visual=\(visualContextLabel(visualContextSession))"
        ]
    }

    private static func sourceLabel(_ sources: Set<TextCaptureSource>) -> String {
        sources
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    private static func stableIdentityLabel(_ identity: StableFieldIdentity?) -> String {
        guard let identity else {
            return "nil"
        }
        return [
            "bundle=\(identity.bundleID)",
            "pid=\(identity.processID)",
            "domain=\(identity.domain ?? "nil")",
            "role=\(identity.role ?? "nil")",
            "subrole=\(identity.subrole ?? "nil")",
            "frame=\(String(describing: identity.roundedFocusedElementFrame))",
            "seq=\(identity.focusChangeSequence.map(String.init) ?? "nil")"
        ].joined(separator: " ")
    }

    private static func visualContextLabel(_ session: VisualContextSession?) -> String {
        guard let session else {
            return "none"
        }
        return "\(session.state.rawValue) source=visualContext-ocr"
    }
}

@MainActor
final class FocusDebugOverlayController: FocusDebugOverlayPresenting {
    private var panel: NSPanel?
    private let options: () -> FocusDebugOverlayOptions
    private let visualContextSessionProvider: () -> VisualContextSession?
    private let screensProvider: () -> [NSScreen]

    init(
        options: @escaping () -> FocusDebugOverlayOptions = { FocusDebugOverlayOptions() },
        visualContextSessionProvider: @escaping () -> VisualContextSession? = { nil },
        screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens }
    ) {
        self.options = options
        self.visualContextSessionProvider = visualContextSessionProvider
        self.screensProvider = screensProvider
    }

    func show(context: TextContext, tier: PreviewPresentationTier) {
        guard options().isEnabled else {
            hide()
            return
        }

        let screens = screensProvider()
        guard let screen = screen(containing: context, screens: screens) else {
            hide()
            return
        }

        guard let snapshot = FocusDebugOverlaySnapshot.make(
            context: context,
            tier: tier,
            visualContextSession: visualContextSessionProvider(),
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            screenFrames: screens.map(\.frame)
        ) else {
            hide()
            return
        }

        let panel = panel ?? FloatingSuggestionPanelFactory.makePanel(
            contentRect: snapshot.panelFrame,
            level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        )
        panel.setFrame(snapshot.panelFrame, display: true)
        panel.contentView = NSHostingView(rootView: FocusDebugOverlayView(snapshot: snapshot))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func screen(containing context: TextContext, screens: [NSScreen]) -> NSScreen? {
        let rects = [
            context.caretRect,
            context.focusedElementRect,
            context.previousGlyphRect,
            context.lineReferenceRect,
            context.nextGlyphRect
        ].compactMap { $0 }

        for rect in rects {
            if let screen = screens.first(where: { $0.frame.intersects(rect) || $0.visibleFrame.intersects(rect) }) {
                return screen
            }
        }

        return screens.first ?? NSScreen.main
    }
}

private struct FocusDebugOverlayView: View {
    let snapshot: FocusDebugOverlaySnapshot

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(snapshot.rectangles) { rectangle in
                overlayRectangle(rectangle)
            }
            labelStack
        }
        .frame(width: snapshot.panelFrame.width, height: snapshot.panelFrame.height, alignment: .topLeading)
        .background(Color.clear)
    }

    private var labelStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(snapshot.labels, id: \.self) { label in
                Text(label)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4))
        .padding(10)
    }

    private func overlayRectangle(_ rectangle: FocusDebugOverlayRectangle) -> some View {
        let localRect = localRect(for: rectangle.rect)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color(for: rectangle.kind), style: strokeStyle(for: rectangle.kind))
            Text(rectangle.kind.rawValue)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color(for: rectangle.kind))
                .padding(.horizontal, 3)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                .offset(x: 2, y: 2)
        }
        .frame(width: max(localRect.width, 1), height: max(localRect.height, 1))
        .position(x: localRect.midX, y: localRect.midY)
    }

    private func localRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - snapshot.panelFrame.minX,
            y: snapshot.panelFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func color(for kind: FocusDebugOverlayRectangle.Kind) -> Color {
        switch kind {
        case .caret:
            return .green
        case .focusedElement:
            return .blue
        case .previousGlyph:
            return .orange
        case .nextGlyph:
            return .purple
        case .lineReference:
            return .yellow
        case .screenOCRRegion:
            return .red
        }
    }

    private func strokeStyle(for kind: FocusDebugOverlayRectangle.Kind) -> StrokeStyle {
        switch kind {
        case .screenOCRRegion, .lineReference:
            return StrokeStyle(lineWidth: 2, dash: [6, 4])
        default:
            return StrokeStyle(lineWidth: 2)
        }
    }
}

private extension PreviewPresentationTier {
    var debugLabel: String {
        switch self {
        case .nativeInline:
            return "nativeInline"
        case .multiSuggestionPopup:
            return "multiSuggestionPopup"
        case .visualInlineOverlay:
            return "visualInlineOverlay"
        case .simpleCaretPopup:
            return "simpleCaretPopup"
        case .mirrorWindow:
            return "mirrorWindow"
        case .disabled:
            return "disabled"
        }
    }
}
