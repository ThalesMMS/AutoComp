import AppKit
import AutoCompCore
import SwiftUI

@MainActor
final class EmojiPickerPanelController: EmojiPickerPanelControlling {
    private var panel: NSPanel?

    func show(
        matches: [EmojiMatch],
        selectedIndex: Int,
        preferences: EmojiVariantPreferences,
        anchorContext: TextContext,
        onSelect: @escaping (Int) -> Void
    ) {
        guard !matches.isEmpty,
              let frame = panelFrame(for: matches, context: anchorContext) else {
            hide()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: EmojiPickerPanelView(
            matches: matches,
            selectedIndex: selectedIndex,
            preferences: preferences,
            onSelect: onSelect
        ))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        GeometryDebug.log("emoji-picker show queryCount=\(matches.count) selected=\(selectedIndex) panel=\(frame)")
    }

    func hide() {
        GeometryDebug.log("emoji-picker hide hasPanel=\(panel != nil)")
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = EmojiPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 168),
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

    private func panelFrame(for matches: [EmojiMatch], context: TextContext) -> NSRect? {
        guard let anchorRect = context.caretRect
            ?? context.previousGlyphRect
            ?? context.nextGlyphRect
            ?? context.lineReferenceRect
            ?? context.focusedElementRect else {
            return nil
        }

        let screen = OverlayGeometry.screen(containingAccessibilityRect: anchorRect)
        let mainScreenFrame = NSScreen.screens.first?.frame ?? screen.frame
        let anchor = OverlayGeometry.appKitRect(
            accessibilityRect: anchorRect,
            screenFrame: mainScreenFrame
        )
        let rowCount = min(5, max(1, matches.count))
        let width: CGFloat = 300
        let height = CGFloat(rowCount * 32 + 8)
        let visibleFrame = screen.visibleFrame
        let belowY = anchor.minY - height - 6
        let desiredY = belowY >= visibleFrame.minY ? belowY : anchor.maxY + 6
        let desiredOrigin = CGPoint(x: anchor.minX, y: desiredY)
        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - width)),
            y: min(max(desiredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - height))
        )
        return NSRect(x: clampedOrigin.x, y: clampedOrigin.y, width: width, height: height)
    }
}

private final class EmojiPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct EmojiPickerPanelView: View {
    let matches: [EmojiMatch]
    let selectedIndex: Int
    let preferences: EmojiVariantPreferences
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                Button {
                    onSelect(index)
                } label: {
                    HStack(spacing: 8) {
                        Text(preferences.glyph(for: match.entry))
                            .font(.system(size: 18))
                            .frame(width: 24)
                        Text(":\(match.entry.primaryAlias):")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(match.entry.keywords.prefix(2).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
