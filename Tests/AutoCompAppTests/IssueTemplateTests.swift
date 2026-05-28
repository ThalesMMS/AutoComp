import Foundation
import XCTest

final class IssueTemplateTests: XCTestCase {
    func testTemplatesCoverBetaBugClasses() throws {
        let templates = try templateContents()
        XCTAssertEqual(
            Set(templates.keys),
            [
                "backend_model_bug.yml",
                "context_capture_bug.yml",
                "insertion_shortcut_bug.yml",
                "overlay_geometry_bug.yml",
                "privacy_security_bug.yml",
                "release_update_bug.yml"
            ]
        )

        let combined = templates.values.joined(separator: "\n")
        for requiredText in [
            "Overlay / geometry bug",
            "Context capture bug",
            "Backend / model bug",
            "Insertion / shortcut bug",
            "Privacy / security bug",
            "Release / update bug"
        ] {
            XCTAssertTrue(combined.contains(requiredText), "Missing issue class: \(requiredText)")
        }
    }

    func testTemplatesAskForSafeActionableContext() throws {
        let templates = try templateContents()
        for (name, body) in templates {
            for requiredText in [
                "Attach redacted logs and safe screenshots only.",
                "Do not paste sensitive field text, prompts, clipboard content, OCR text, API keys, or debug artifacts.",
                "Version and build",
                "App, bundle ID, and domain",
                "browser domain only when safe and relevant",
                "Activation mode",
                "Backend",
                "Permissions",
                "Input source",
                "Overlay tier",
                "QA row or report",
                "redacted settings export",
                "I removed sensitive field text, prompts, clipboard content, OCR text, API keys, and debug artifacts."
            ] {
                XCTAssertTrue(body.contains(requiredText), "\(name) missing required text: \(requiredText)")
            }
        }
    }

    func testTemplatesUseCurrentDiagnosticsTerminology() throws {
        let combined = try templateContents().values.joined(separator: "\n")
        for requiredText in [
            "visualInlineOverlay",
            "simpleCaretPopup",
            "mirrorWindow",
            "multiSuggestionPopup",
            "disabled",
            "source=accessibility",
            "source=ocr-geometry",
            "source=visual-ocr",
            "source=keystroke-buffer",
            "quality=direct",
            "quality=glyph",
            "quality=line",
            "quality=element",
            "quality=ocr",
            "quality=unavailable",
            "trust=standard",
            "trust=low-trust",
            "input-source-non-ascii",
            "ime-composition-active",
            "manual-only-waiting-for-trigger",
            "blocked-risky-host-app",
            "unavailable-appleevents-denied",
            "unavailable-browser-script-failed"
        ] {
            XCTAssertTrue(combined.contains(requiredText), "Missing diagnostics term: \(requiredText)")
        }
    }

    func testTemplateLabelsMatchRepositoryTaxonomy() throws {
        let knownLabels: Set<String> = [
            "a11y",
            "bug",
            "compatibility",
            "core",
            "diagnostics",
            "geometry",
            "keyboard",
            "llm",
            "local-llm",
            "networking",
            "privacy",
            "release",
            "resilience",
            "storage",
            "testing",
            "ui"
        ]

        for (name, body) in try templateContents() {
            let labels = templateLabels(in: body)
            XCTAssertFalse(labels.isEmpty, "\(name) does not define labels")
            for label in labels {
                XCTAssertTrue(knownLabels.contains(label), "\(name) uses unknown label: \(label)")
            }
        }
    }

    func testBlankIssuesAreDisabled() throws {
        let config = try String(
            contentsOf: try repositoryRoot()
                .appendingPathComponent(".github/ISSUE_TEMPLATE/config.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("blank_issues_enabled: false"))
    }

    private func templateContents() throws -> [String: String] {
        let directory = try repositoryRoot().appendingPathComponent(".github/ISSUE_TEMPLATE")
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "yml" && $0.lastPathComponent != "config.yml" }

        return Dictionary(uniqueKeysWithValues: try urls.map { url in
            (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
        })
    }

    private func templateLabels(in body: String) -> [String] {
        guard let line = body.split(separator: "\n").first(where: { $0.hasPrefix("labels: [") }) else {
            return []
        }

        return line
            .replacingOccurrences(of: "labels: [", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
    }

    private func repositoryRoot() throws -> URL {
        try packageRoot().deletingLastPathComponent()
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }
}
