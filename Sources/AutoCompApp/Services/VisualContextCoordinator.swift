import AppKit
import AutoCompCore
import Foundation
import ScreenCaptureKit
import Vision

struct VisualTextObservation: Equatable, Sendable {
    let text: String
    let captureSource: TextCaptureSource

    init(text: String, captureSource: TextCaptureSource = .screenOCR) {
        self.text = text
        self.captureSource = captureSource
    }
}

protocol VisualTextCapturing: Sendable {
    func captureVisibleText() async -> [VisualTextObservation]
}

final class VisualContextCoordinator: VisualContextProvider, @unchecked Sendable {
    private let privacyStore: PrivacySettingsStore
    private let visualTextCapturer: any VisualTextCapturing
    private let screenCaptureAllowed: () -> Bool
    private let maxSummaryCharacters: Int

    init(
        privacyStore: PrivacySettingsStore,
        visualTextCapturer: any VisualTextCapturing = ScreenOCRVisualTextCapturer(),
        screenCaptureAllowed: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        maxSummaryCharacters: Int = 700
    ) {
        self.privacyStore = privacyStore
        self.visualTextCapturer = visualTextCapturer
        self.screenCaptureAllowed = screenCaptureAllowed
        self.maxSummaryCharacters = max(80, maxSummaryCharacters)
    }

    func currentVisualContext() async -> VisualContextSnapshot? {
        let settings = privacyStore.load()
        guard settings.screenContextEnabled,
              screenCaptureAllowed() else {
            return nil
        }

        let observations = await visualTextCapturer.captureVisibleText()
        var sources = Set<TextCaptureSource>()
        var seenLines = Set<String>()
        var lines: [String] = []

        for observation in observations {
            let line = normalizedLine(observation.text)
            guard !line.isEmpty,
                  seenLines.insert(line).inserted else {
                continue
            }
            sources.insert(observation.captureSource)
            lines.append(line)
        }

        let summary = limitedSummary(from: lines)
        guard !summary.isEmpty,
              !sources.isEmpty else {
            return nil
        }

        return VisualContextSnapshot(summary: summary, captureSources: sources)
    }

    private func normalizedLine(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func limitedSummary(from lines: [String]) -> String {
        var summary = ""
        for line in lines {
            let separator = summary.isEmpty ? "" : "\n"
            let candidate = summary + separator + line
            if candidate.count > maxSummaryCharacters {
                let remaining = maxSummaryCharacters - summary.count - separator.count
                if remaining > 0 {
                    summary += separator + String(line.prefix(remaining))
                }
                break
            }
            summary = candidate
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ScreenOCRVisualTextCapturer: VisualTextCapturing {
    func captureVisibleText() async -> [VisualTextObservation] {
        guard CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first,
              let image = await captureScreenImage(in: screen.frame) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["pt-BR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? [])
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { observation in
                guard observation.boundingBox.width >= 0.01,
                      observation.boundingBox.height >= 0.005,
                      let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }
                return VisualTextObservation(text: text, captureSource: .screenOCR)
            }
    }

    private func captureScreenImage(in rect: CGRect) async -> CGImage? {
        guard #available(macOS 15.2, *) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
