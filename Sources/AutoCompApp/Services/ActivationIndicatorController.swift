import AppKit
import AutoCompCore

enum ActivationIndicatorMode: String, CaseIterable, Equatable {
    case hidden
    case fieldEdge
    case caretAnchor
    case debugGeometryQuality
}

struct ActivationIndicatorPlacement: Equatable {
    let frame: CGRect
    let mode: ActivationIndicatorMode
    let geometryQuality: CaretGeometryQuality
    let stableFieldIdentity: StableFieldIdentity?

    init(
        frame: CGRect,
        mode: ActivationIndicatorMode,
        geometryQuality: CaretGeometryQuality = .unavailable,
        stableFieldIdentity: StableFieldIdentity? = nil
    ) {
        self.frame = frame
        self.mode = mode
        self.geometryQuality = geometryQuality
        self.stableFieldIdentity = stableFieldIdentity
    }
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

    init(mode: ActivationIndicatorMode? = nil) {
        self.mode = mode ?? Self.defaultMode()
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

        let panel = panel ?? Self.makePanel(size: placement.frame.size)
        self.panel = panel
        let contentView: ActivationIndicatorView
        if let existingView = panel.contentView as? ActivationIndicatorView {
            contentView = existingView
        } else {
            contentView = ActivationIndicatorView(frame: CGRect(origin: .zero, size: placement.frame.size))
            panel.contentView = contentView
        }
        contentView.frame = CGRect(origin: .zero, size: placement.frame.size)
        contentView.update(mode: placement.mode, geometryQuality: placement.geometryQuality)
        panel.setFrame(placement.frame, display: true)
        GeometryDebug.log("activation-indicator mode=\(placement.mode.rawValue) frame=\(placement.frame) quality=\(context.caretGeometryQuality.rawValue) stableField=\(String(describing: placement.stableFieldIdentity))")
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    static func placement(
        mode: ActivationIndicatorMode,
        displayMode: SuggestionDisplayMode,
        context: TextContext,
        size: CGSize? = nil
    ) -> ActivationIndicatorPlacement? {
        let resolvedSize = size ?? Self.size(for: mode)
        guard mode != .hidden,
              displayMode != .disabled,
              (context.selectedRange?.length ?? 0) == 0 else {
            return nil
        }

        switch mode {
        case .hidden:
            return nil
        case .caretAnchor:
            guard let anchor = caretAnchor(for: context) else {
                return nil
            }
            return ActivationIndicatorPlacement(
                frame: caretFrame(anchor: anchor, size: resolvedSize),
                mode: mode,
                geometryQuality: context.caretGeometryQuality,
                stableFieldIdentity: context.stableFieldIdentity
            )
        case .fieldEdge:
            guard let anchor = context.focusedElementRect ?? context.caretRect else {
                return nil
            }
            return ActivationIndicatorPlacement(
                frame: fieldEdgeFrame(anchor: anchor, size: resolvedSize),
                mode: mode,
                geometryQuality: context.caretGeometryQuality,
                stableFieldIdentity: context.stableFieldIdentity
            )
        case .debugGeometryQuality:
            if let anchor = caretAnchor(for: context) {
                return ActivationIndicatorPlacement(
                    frame: caretFrame(anchor: anchor, size: resolvedSize),
                    mode: mode,
                    geometryQuality: context.caretGeometryQuality,
                    stableFieldIdentity: context.stableFieldIdentity
                )
            }
            guard let anchor = context.focusedElementRect else {
                return nil
            }
            return ActivationIndicatorPlacement(
                frame: fieldEdgeFrame(anchor: anchor, size: resolvedSize),
                mode: mode,
                geometryQuality: context.caretGeometryQuality,
                stableFieldIdentity: context.stableFieldIdentity
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

    static func defaultMode(isGeometryDebugEnabled: Bool = GeometryDebug.isEnabled) -> ActivationIndicatorMode {
        isGeometryDebugEnabled ? .debugGeometryQuality : .fieldEdge
    }

    static func debugLabel(for quality: CaretGeometryQuality) -> String {
        switch quality {
        case .directCaret:
            return "direct"
        case .glyph:
            return "glyph"
        case .lineMetric:
            return "line"
        case .elementFrame:
            return "element"
        case .screenOCR:
            return "OCR"
        case .unavailable:
            return "unavailable"
        }
    }

    private static func size(for mode: ActivationIndicatorMode) -> CGSize {
        mode == .debugGeometryQuality
            ? CGSize(width: 76, height: 18)
            : CGSize(width: 8, height: 8)
    }

    private static func caretAnchor(for context: TextContext) -> CGRect? {
        context.caretRect
            ?? context.previousGlyphRect
            ?? context.lineReferenceRect
    }

    private static func caretFrame(anchor: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: anchor.maxX + 4,
            y: anchor.minY + max(0, (anchor.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }

    private static func fieldEdgeFrame(anchor: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: anchor.maxX - size.width - 6,
            y: anchor.minY + 6,
            width: size.width,
            height: size.height
        )
    }
}

private final class ActivationIndicatorView: NSView {
    private var mode: ActivationIndicatorMode = .fieldEdge
    private var geometryQuality: CaretGeometryQuality = .unavailable

    override var isFlipped: Bool { true }

    func update(mode: ActivationIndicatorMode, geometryQuality: CaretGeometryQuality) {
        self.mode = mode
        self.geometryQuality = geometryQuality
        toolTip = mode == .debugGeometryQuality
            ? "Geometry quality: \(ActivationIndicatorController.debugLabel(for: geometryQuality))"
            : nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        if mode == .debugGeometryQuality {
            drawDebugQualityPill()
        } else {
            let circleRect = bounds.insetBy(dx: 1, dy: 1)
            NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.84, alpha: 0.78).setFill()
            NSBezierPath(ovalIn: circleRect).fill()
        }
    }

    private func drawDebugQualityPill() {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let colors = debugColors(for: geometryQuality)
        colors.fill.setFill()
        colors.stroke.setStroke()
        path.lineWidth = 1
        path.fill()
        path.stroke()

        let label = ActivationIndicatorController.debugLabel(for: geometryQuality)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: colors.text
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(
                x: max(3, (bounds.width - size.width) / 2),
                y: max(1, (bounds.height - size.height) / 2)
            ),
            withAttributes: attributes
        )
    }

    private func debugColors(for quality: CaretGeometryQuality) -> (fill: NSColor, stroke: NSColor, text: NSColor) {
        switch quality {
        case .directCaret:
            return (
                NSColor(calibratedRed: 0.05, green: 0.38, blue: 0.18, alpha: 0.9),
                NSColor(calibratedRed: 0.17, green: 0.78, blue: 0.36, alpha: 0.95),
                .white
            )
        case .glyph:
            return (
                NSColor(calibratedRed: 0.03, green: 0.33, blue: 0.36, alpha: 0.9),
                NSColor(calibratedRed: 0.15, green: 0.74, blue: 0.78, alpha: 0.95),
                .white
            )
        case .lineMetric:
            return (
                NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.52, alpha: 0.9),
                NSColor(calibratedRed: 0.33, green: 0.56, blue: 0.95, alpha: 0.95),
                .white
            )
        case .elementFrame:
            return (
                NSColor(calibratedRed: 0.51, green: 0.29, blue: 0.05, alpha: 0.9),
                NSColor(calibratedRed: 0.96, green: 0.61, blue: 0.18, alpha: 0.95),
                .white
            )
        case .screenOCR:
            return (
                NSColor(calibratedRed: 0.32, green: 0.18, blue: 0.55, alpha: 0.9),
                NSColor(calibratedRed: 0.68, green: 0.48, blue: 0.95, alpha: 0.95),
                .white
            )
        case .unavailable:
            return (
                NSColor(calibratedWhite: 0.18, alpha: 0.9),
                NSColor(calibratedWhite: 0.62, alpha: 0.95),
                .white
            )
        }
    }
}
