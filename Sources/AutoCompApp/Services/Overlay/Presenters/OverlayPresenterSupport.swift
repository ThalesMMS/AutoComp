import AppKit
import AutoCompCore

@MainActor
struct OverlayPresenterGeometry {
    struct ScreenContext {
        let anchorRect: CGRect
        let visibleFrame: NSRect
        let mainScreenFrame: NSRect
        let screenFrames: [NSRect]
    }

    static func anchorRect(for context: TextContext) -> CGRect? {
        context.caretRect
            ?? context.previousGlyphRect
            ?? context.nextGlyphRect
            ?? context.lineReferenceRect
            ?? context.focusedElementRect
    }

    static func screenContext(for context: TextContext) -> ScreenContext? {
        guard let anchorRect = anchorRect(for: context) else {
            return nil
        }

        let screen = OverlayGeometry.screen(containingAccessibilityRect: anchorRect)
        return ScreenContext(
            anchorRect: anchorRect,
            visibleFrame: screen.visibleFrame,
            mainScreenFrame: NSScreen.screens.first?.frame ?? screen.frame,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }
}

@MainActor
final class OverlayPanelHost<ContentView: NSView> {
    private var panel: NSPanel?
    private var contentView: ContentView?
    private let contentRect: NSRect
    private let level: NSWindow.Level
    private let makeContentView: (NSPanel) -> ContentView

    init(
        contentRect: NSRect,
        level: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2),
        makeContentView: @escaping (NSPanel) -> ContentView
    ) {
        self.contentRect = contentRect
        self.level = level
        self.makeContentView = makeContentView
    }

    var hasPanel: Bool {
        panel != nil
    }

    func resolve() -> (panel: NSPanel, contentView: ContentView) {
        let panel = panel ?? FloatingSuggestionPanelFactory.makePanel(
            contentRect: contentRect,
            level: level
        )
        self.panel = panel

        let contentView = contentView ?? makeContentView(panel)
        self.contentView = contentView
        return (panel, contentView)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct OverlayShortcutHintResolver {
    private let shortcutSettingsStore: KeyboardShortcutSettingsStore
    private let hintsProvider: OverlayShortcutHintsProvider

    init(
        shortcutSettingsStore: KeyboardShortcutSettingsStore,
        hintsProvider: OverlayShortcutHintsProvider
    ) {
        self.shortcutSettingsStore = shortcutSettingsStore
        self.hintsProvider = hintsProvider
    }

    func hints() -> OverlayShortcutHints {
        hintsProvider.hints(from: shortcutSettingsStore.load())
    }
}

enum OverlayPresenterLog {
    static func rejected(
        tier: String,
        context: TextContext,
        reason: String? = nil
    ) {
        let reasonText = reason.map { " reason=\($0)" } ?? ""
        GeometryDebug.log("tier=\(tier) rejected app=\(context.app.displayName) bundle=\(context.app.bundleID)\(reasonText) context=\(context.geometryDebugDescription)")
    }

    static func hide(tier: String, hasPanel: Bool) {
        GeometryDebug.log("tier=\(tier) hide hasPanel=\(hasPanel)")
    }
}
