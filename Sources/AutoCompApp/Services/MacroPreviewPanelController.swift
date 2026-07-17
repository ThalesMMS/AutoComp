import AppKit
import AutoCompCore
import SwiftUI

@MainActor
protocol MacroPreviewPanelControlling: AnyObject {
    func show(value: MacroValue, anchorContext: TextContext, acceptKeyLabel: String, onCommit: @escaping () -> Void)
    func hide()
}

@MainActor
final class MacroPreviewPanelController: MacroPreviewPanelControlling {
    private var panel: NSPanel?

    func show(value: MacroValue, anchorContext: TextContext, acceptKeyLabel: String, onCommit: @escaping () -> Void) {
        guard let frame = panelFrame(context: anchorContext) else {
            hide()
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: MacroPreviewView(
            value: value,
            acceptKeyLabel: acceptKeyLabel,
            onCommit: onCommit
        ))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = MacroPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }

    private func panelFrame(context: TextContext) -> NSRect? {
        guard let anchorRect = context.caretRect
            ?? context.previousGlyphRect
            ?? context.nextGlyphRect
            ?? context.lineReferenceRect
            ?? context.focusedElementRect else { return nil }
        let screen = OverlayGeometry.screen(containingAccessibilityRect: anchorRect)
        let mainScreenFrame = NSScreen.screens.first?.frame ?? screen.frame
        let anchor = OverlayGeometry.appKitRect(accessibilityRect: anchorRect, screenFrame: mainScreenFrame)
        let size = CGSize(width: 320, height: 52)
        let desired = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: min(max(desired.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
            y: min(max(desired.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        )
        return NSRect(origin: origin, size: size)
    }
}

private final class MacroPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct MacroPreviewView: View {
    let value: MacroValue
    let acceptKeyLabel: String
    let onCommit: () -> Void

    var body: some View {
        Button(action: onCommit) {
            HStack(spacing: 10) {
                Image(systemName: "function")
                    .foregroundStyle(.secondary)
                Text(value.preview)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(acceptKeyLabel)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
