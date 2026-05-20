import AppKit
import AutoCompCore

enum ActivationIndicatorMode: String, CaseIterable, Equatable {
    case hidden
    case caretAnchor
    case fieldEdge
}

struct ActivationIndicatorPlacement: Equatable {
    let frame: CGRect
    let mode: ActivationIndicatorMode
}

@MainActor
protocol ActivationIndicatorPresenting: AnyObject {
    func show(for context: TextContext, displayMode: SuggestionDisplayMode)
    func hide()
}

@MainActor
final class ActivationIndicatorController: ActivationIndicatorPresenting {
    private let mode: ActivationIndicatorMode
    private var panel: NSPanel?
    private let size = CGSize(width: 8, height: 8)

    init(mode: ActivationIndicatorMode = .caretAnchor) {
        self.mode = mode
    }

    func show(for context: TextContext, displayMode: SuggestionDisplayMode) {
        guard let placement = Self.placement(
            mode: mode,
            displayMode: displayMode,
            context: context
        ) else {
            hide()
            return
        }

        let panel = panel ?? Self.makePanel(size: size)
        self.panel = panel
        if panel.contentView == nil {
            panel.contentView = ActivationIndicatorView(frame: CGRect(origin: .zero, size: size))
        }
        panel.setFrame(placement.frame, display: true)
        GeometryDebug.log("activation-indicator mode=\(placement.mode.rawValue) frame=\(placement.frame) quality=\(context.caretGeometryQuality.rawValue)")
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    static func placement(
        mode: ActivationIndicatorMode,
        displayMode: SuggestionDisplayMode,
        context: TextContext,
        size: CGSize = CGSize(width: 8, height: 8)
    ) -> ActivationIndicatorPlacement? {
        guard mode != .hidden,
              displayMode != .disabled,
              (context.selectedRange?.length ?? 0) == 0 else {
            return nil
        }

        switch mode {
        case .hidden:
            return nil
        case .caretAnchor:
            guard let anchor = context.caretRect
                ?? context.previousGlyphRect
                ?? context.lineReferenceRect else {
                return nil
            }
            return ActivationIndicatorPlacement(
                frame: CGRect(
                    x: anchor.maxX + 4,
                    y: anchor.minY + max(0, (anchor.height - size.height) / 2),
                    width: size.width,
                    height: size.height
                ),
                mode: mode
            )
        case .fieldEdge:
            guard let anchor = context.focusedElementRect ?? context.caretRect else {
                return nil
            }
            return ActivationIndicatorPlacement(
                frame: CGRect(
                    x: anchor.maxX - size.width - 6,
                    y: anchor.minY + 6,
                    width: size.width,
                    height: size.height
                ),
                mode: mode
            )
        }
    }

    static func makePanel(size: CGSize = CGSize(width: 8, height: 8)) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

private final class ActivationIndicatorView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let circleRect = bounds.insetBy(dx: 1, dy: 1)
        NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.84, alpha: 0.78).setFill()
        NSBezierPath(ovalIn: circleRect).fill()
    }
}
