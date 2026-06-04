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
        writeUnredactedDebugArtifact(resolvedMessage)
    }

    /// Writes an intentionally unredacted geometry artifact for controlled developer and CI smoke runs.
    ///
    /// Unified log and stderr output stay redacted above; this file path is opt-in because UI geometry
    /// smoke tests need exact fields such as tier, panel frame, and suffix length.
    private static func writeUnredactedDebugArtifact(_ resolvedMessage: String) {
        if let path = ProcessInfo.processInfo.environment["AUTOCOMP_GEOMETRY_DEBUG_LOG_FILE"],
           !path.isEmpty,
           let data = "AutoCompGeometry \(resolvedMessage)\n".data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
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

struct NativeInlinePresentationAvailability: Equatable, Sendable {
    let canPresent: Bool
    let diagnosticReason: String?

    static let supported = NativeInlinePresentationAvailability(
        canPresent: true,
        diagnosticReason: nil
    )

    static func unsupported(reason: String) -> NativeInlinePresentationAvailability {
        NativeInlinePresentationAvailability(
            canPresent: false,
            diagnosticReason: reason
        )
    }
}

@MainActor
protocol NativeInlineSuggestionPresenting: SuggestionTierPresenting {
    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool
    func availability(for suggestion: Suggestion, context: TextContext) -> NativeInlinePresentationAvailability
}

extension NativeInlineSuggestionPresenting {
    func availability(for suggestion: Suggestion, context: TextContext) -> NativeInlinePresentationAvailability {
        canPresent(suggestion, for: context)
            ? .supported
            : .unsupported(reason: "native-inline-presenter-declined")
    }
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
