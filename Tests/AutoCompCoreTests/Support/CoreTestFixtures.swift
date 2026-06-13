import AutoCompCore
import CoreGraphics
import Foundation
import XCTest

extension XCTestCase {
    func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }

    func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: try packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    func makeContext(
        focusedElementID: String = "field",
        textBeforeCursor: String = "Can you ",
        textAfterCursor: String? = nil,
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        domain: String? = nil,
        stableFieldIdentity: StableFieldIdentity? = nil,
        selectedText: String? = nil,
        fullTextWindow: String? = nil,
        selectedRange: NSRange? = nil,
        caretRect: CGRect? = nil,
        focusedElementRect: CGRect? = nil,
        previousGlyphRect: CGRect? = nil,
        nextGlyphRect: CGRect? = nil,
        lineReferenceRect: CGRect? = nil,
        caretGeometryQuality: CaretGeometryQuality = .unavailable,
        observedCharacterWidth: CGFloat? = nil,
        languageHint: String? = nil,
        captureSources: Set<TextCaptureSource> = [.accessibility],
        createdAt: Date = Date()
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            stableFieldIdentity: stableFieldIdentity,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            selectedText: selectedText,
            fullTextWindow: fullTextWindow,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            languageHint: languageHint,
            captureSources: captureSources,
            createdAt: createdAt
        )
    }

    func makeTemporaryDirectory(prefix: String = "AutoCompTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
