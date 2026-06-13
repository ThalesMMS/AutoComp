import AppKit
import AutoCompCore
import Foundation
import ScreenCaptureKit
import Vision

struct VisualTextObservation: Equatable, Sendable {
    let text: String
    let captureSource: TextCaptureSource
    let confidence: Float

    init(
        text: String,
        captureSource: TextCaptureSource = .screenOCR,
        confidence: Float = 1
    ) {
        self.text = text
        self.captureSource = captureSource
        self.confidence = confidence
    }
}

protocol VisualTextCapturing: Sendable {
    func captureVisibleText() async -> [VisualTextObservation]
}

protocol WindowScreenshotCapturing: Sendable {
    func capturePrimaryScreenImage() async -> CGImage?
}

final class ScreenCaptureCooldown: @unchecked Sendable {
    static let shared = ScreenCaptureCooldown()

    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastFailureAt: Date?

    init(
        interval: TimeInterval = 8,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.interval = max(0, interval)
        self.now = now
    }

    var isActive: Bool {
        lock.withLock {
            guard interval > 0,
                  let lastFailureAt else {
                return false
            }
            return now().timeIntervalSince(lastFailureAt) < interval
        }
    }

    func recordFailure() {
        guard interval > 0 else {
            return
        }
        lock.withLock {
            lastFailureAt = now()
        }
    }

    func clearFailure() {
        lock.withLock {
            lastFailureAt = nil
        }
    }
}

final class WindowScreenshotService: WindowScreenshotCapturing, @unchecked Sendable {
    typealias CaptureImage = @Sendable (CGRect, @escaping @Sendable (CGImage?) -> Void) -> Void

    private let timeout: TimeInterval
    private let screenCaptureCooldown: ScreenCaptureCooldown
    private let isCaptureAvailable: @Sendable () -> Bool
    private let screenFrameProvider: @Sendable () -> CGRect?
    private let captureImage: CaptureImage

    init(
        timeout: TimeInterval = 1.25,
        screenCaptureCooldown: ScreenCaptureCooldown = .shared,
        isCaptureAvailable: @escaping @Sendable () -> Bool = {
            if #available(macOS 15.2, *) {
                return true
            }
            return false
        },
        screenFrameProvider: @escaping @Sendable () -> CGRect? = { NSScreen.screens.first?.frame },
        captureImage: CaptureImage? = nil
    ) {
        self.timeout = timeout
        self.screenCaptureCooldown = screenCaptureCooldown
        self.isCaptureAvailable = isCaptureAvailable
        self.screenFrameProvider = screenFrameProvider
        self.captureImage = captureImage ?? { rect, complete in
            if #available(macOS 15.2, *) {
                SCScreenshotManager.captureImage(in: rect) { image, _ in
                    complete(image)
                }
            } else {
                complete(nil)
            }
        }
    }

    func capturePrimaryScreenImage() async -> CGImage? {
        guard isCaptureAvailable(),
              let screenFrame = screenFrameProvider() else {
            return nil
        }

        guard !screenCaptureCooldown.isActive else {
            GeometryDebug.log("visual-context status=screenshot-cooldown source=visualContext-ocr")
            return nil
        }

        let result: CallbackTimeoutResult<CGImage> = await AsyncTimeout.waitForCallback(
            seconds: timeout,
            onTimeout: {
                GeometryDebug.log("visual-context status=screenshot-timeout source=visualContext-ocr")
            }
        ) { complete in
            captureImage(screenFrame, complete)
        }
        switch result {
        case .completed(let image):
            if image == nil {
                screenCaptureCooldown.recordFailure()
            } else {
                screenCaptureCooldown.clearFailure()
            }
            return image
        case .timedOut:
            screenCaptureCooldown.recordFailure()
            return nil
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
                return VisualTextObservation(
                    text: text,
                    captureSource: .screenOCR,
                    confidence: candidate.confidence
                )
            }
    }
}

struct VisualContextSummary: Equatable, Sendable {
    let text: String
    let captureSources: Set<TextCaptureSource>
}

protocol VisualContextSummarizing: Sendable {
    func summarize(
        _ observations: [VisualTextObservation],
        excludingFieldText fieldText: [String]
    ) -> VisualContextSummary?
}

extension VisualContextSummarizing {
    func summarize(_ observations: [VisualTextObservation]) -> VisualContextSummary? {
        summarize(observations, excludingFieldText: [])
    }
}

struct VisualContextSummarizer: VisualContextSummarizing {
    private let maxCharacters: Int
    private let maxLines: Int
    private let minimumConfidence: Float

    init(maxCharacters: Int = 700, maxLines: Int = 12, minimumConfidence: Float = 0.35) {
        self.maxCharacters = max(80, maxCharacters)
        self.maxLines = max(1, maxLines)
        self.minimumConfidence = min(max(0, minimumConfidence), 1)
    }

    func summarize(
        _ observations: [VisualTextObservation],
        excludingFieldText fieldText: [String] = []
    ) -> VisualContextSummary? {
        var sources = Set<TextCaptureSource>()
        var seenLines = Set<String>()
        var lines: [String] = []
        let excludedFieldText = normalizedExcludedFieldText(fieldText)

        for observation in observations {
            guard observation.confidence >= minimumConfidence else {
                continue
            }
            let line = normalizedLine(observation.text)
            guard !line.isEmpty,
                  isPlausibleOCRLine(line),
                  !matchesExcludedFieldText(line, excludedFieldText),
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

    private func normalizedExcludedFieldText(_ values: [String]) -> [String] {
        values
            .map(normalizedLine)
            .filter { $0.count >= 3 }
    }

    private func matchesExcludedFieldText(_ line: String, _ excludedFieldText: [String]) -> Bool {
        guard line.count >= 3 else {
            return false
        }

        return excludedFieldText.contains { fieldText in
            fieldText == line
                || (line.count >= 8 && fieldText.contains(line))
                || (fieldText.count >= 8 && line.contains(fieldText))
        }
    }

    private func isPlausibleOCRLine(_ line: String) -> Bool {
        guard line.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }),
              !line.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else {
            return false
        }

        let scalars = line.unicodeScalars
        let symbolCount = scalars.filter {
            !CharacterSet.alphanumerics.contains($0)
                && !CharacterSet.whitespaces.contains($0)
        }.count
        guard !scalars.isEmpty else {
            return false
        }

        return Double(symbolCount) / Double(scalars.count) <= 0.65
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
