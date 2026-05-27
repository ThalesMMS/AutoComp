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

protocol WindowScreenshotCapturing: Sendable {
    func capturePrimaryScreenImage() async -> CGImage?
}

struct WindowScreenshotService: WindowScreenshotCapturing {
    func capturePrimaryScreenImage() async -> CGImage? {
        guard #available(macOS 15.2, *),
              let screen = NSScreen.screens.first else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: screen.frame) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

protocol ScreenTextExtracting: Sendable {
    func extractText(from image: CGImage) -> [VisualTextObservation]
}

struct ScreenTextExtractor: ScreenTextExtracting {
    func extractText(from image: CGImage) -> [VisualTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["pt-BR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            GeometryDebug.log("visual-context status=ocr-failed source=visualContext-ocr")
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
}

struct VisualContextSummary: Equatable, Sendable {
    let text: String
    let captureSources: Set<TextCaptureSource>
}

protocol VisualContextSummarizing: Sendable {
    func summarize(_ observations: [VisualTextObservation]) -> VisualContextSummary?
}

struct VisualContextSummarizer: VisualContextSummarizing {
    private let maxCharacters: Int
    private let maxLines: Int

    init(maxCharacters: Int = 700, maxLines: Int = 12) {
        self.maxCharacters = max(80, maxCharacters)
        self.maxLines = max(1, maxLines)
    }

    func summarize(_ observations: [VisualTextObservation]) -> VisualContextSummary? {
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
        return VisualContextSummary(text: summary, captureSources: sources)
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
        for line in lines.prefix(maxLines) {
            let separator = summary.isEmpty ? "" : "\n"
            let candidate = summary + separator + line
            if candidate.count > maxCharacters {
                let remaining = maxCharacters - summary.count - separator.count
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

struct VisualContextOCRCapturer: VisualTextCapturing {
    private let screenshotService: any WindowScreenshotCapturing
    private let textExtractor: any ScreenTextExtracting
    private let screenCaptureAllowed: @Sendable () -> Bool

    init(
        screenshotService: any WindowScreenshotCapturing = WindowScreenshotService(),
        textExtractor: any ScreenTextExtracting = ScreenTextExtractor(),
        screenCaptureAllowed: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.screenshotService = screenshotService
        self.textExtractor = textExtractor
        self.screenCaptureAllowed = screenCaptureAllowed
    }

    func captureVisibleText() async -> [VisualTextObservation] {
        guard screenCaptureAllowed() else {
            GeometryDebug.log("visual-context status=screen-recording-off source=visualContext-ocr")
            return []
        }

        guard let image = await screenshotService.capturePrimaryScreenImage() else {
            GeometryDebug.log("visual-context status=screenshot-unavailable source=visualContext-ocr")
            return []
        }

        let observations = textExtractor.extractText(from: image)
        GeometryDebug.log("visual-context status=ocr-complete source=visualContext-ocr lines=\(observations.count)")
        return observations
    }
}
