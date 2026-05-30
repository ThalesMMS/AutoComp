import AppKit
import AutoCompCore
import SwiftUI

// Shared overlay-layer types that are referenced across presenters and the overlay service.

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
        logger.info("AutoCompGeometry \(AutoCompLogger.redactedSummary(for: resolvedMessage))")
        if let data = "AutoCompGeometry \(AutoCompLogger.redactedSummary(for: resolvedMessage))\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

enum RefreshDiagnostics {
    private static let logger = AutoCompLogger(category: "refresh")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--refresh-debug")
            || ProcessInfo.processInfo.environment["AUTOCOMP_REFRESH_DEBUG"] == "1"
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }
        let resolvedMessage = message()
        logger.info("AutoCompRefresh \(AutoCompLogger.redactedSummary(for: resolvedMessage))")
        if let data = "AutoCompRefresh \(AutoCompLogger.redactedSummary(for: resolvedMessage))\n".data(using: .utf8) {
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
