import AutoCompCore
import Foundation

struct ContextCaptureDiagnostics: Equatable {
    let contextSourceTitle: String
    let contextSourceLogValue: String
    let geometryQualityTitle: String
    let geometryQualityLogValue: String
    let trustTitle: String
    let lowTrustWarning: String?
    let supplementalSourceTitle: String
    let supplementalSourceLogValue: String
    let visualContextLogValue: String
    let clipboardContextLogValue: String

    init(
        context: TextContext,
        visualContext: VisualContextSnapshot? = nil,
        clipboardContext: ClipboardContextSnapshot? = nil
    ) {
        let sourceLabels = Self.contextSourceLabels(for: context.captureSources)
        contextSourceTitle = Self.joinTitle(sourceLabels.map(\.title), fallback: "Unavailable")
        contextSourceLogValue = Self.joinLogValue(sourceLabels.map(\.logValue), fallback: "unavailable")
        geometryQualityTitle = Self.geometryQualityTitle(context.caretGeometryQuality)
        geometryQualityLogValue = Self.geometryQualityLogValue(context.caretGeometryQuality)

        let isLowTrust = context.captureSources.contains(.keystrokeBufferLowTrust)
        trustTitle = isLowTrust ? "low-trust" : "standard"
        lowTrustWarning = isLowTrust
            ? "Low-trust fallback: visual and clipboard context isolated."
            : nil

        let supplementalSources = Self.supplementalSourceLabels(
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            isLowTrust: isLowTrust
        )
        supplementalSourceTitle = Self.joinTitle(supplementalSources.map(\.title), fallback: "none")
        supplementalSourceLogValue = Self.joinLogValue(supplementalSources.map(\.logValue), fallback: "none")
        visualContextLogValue = Self.visualContextLogValue(visualContext)
        clipboardContextLogValue = Self.clipboardContextLogValue(clipboardContext)
    }

    private static func contextSourceLabels(for sources: Set<TextCaptureSource>) -> [SourceLabel] {
        TextCaptureSource.allCases.compactMap { source in
            guard sources.contains(source) else {
                return nil
            }
            switch source {
            case .accessibility:
                return SourceLabel(title: "Accessibility", logValue: "accessibility")
            case .screenOCR:
                return SourceLabel(title: "OCR geometry", logValue: "ocr-geometry")
            case .clipboard:
                return SourceLabel(title: "Clipboard", logValue: "clipboard")
            case .keystrokeBufferLowTrust:
                return SourceLabel(title: "Keystroke buffer", logValue: "keystroke-buffer")
            }
        }
    }

    private static func supplementalSourceLabels(
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        isLowTrust: Bool
    ) -> [SourceLabel] {
        if isLowTrust {
            return [
                SourceLabel(
                    title: "none (low-trust isolation)",
                    logValue: "none-low-trust-isolation"
                )
            ]
        }

        var labels: [SourceLabel] = []
        if visualContext?.isEmpty == false {
            labels.append(SourceLabel(title: "Visual OCR", logValue: "visual-ocr"))
        }
        if clipboardContext?.isIncluded == true {
            labels.append(SourceLabel(title: "Clipboard", logValue: "clipboard"))
        }
        return labels
    }

    private static func geometryQualityTitle(_ quality: CaretGeometryQuality) -> String {
        switch quality {
        case .directCaret:
            return "direct"
        case .glyph:
            return "glyph"
        case .lineMetric:
            return "line"
        case .elementFrame:
            return "element"
        case .screenOCR:
            return "OCR"
        case .unavailable:
            return "unavailable"
        }
    }

    private static func geometryQualityLogValue(_ quality: CaretGeometryQuality) -> String {
        switch quality {
        case .directCaret:
            return "direct"
        case .glyph:
            return "glyph"
        case .lineMetric:
            return "line"
        case .elementFrame:
            return "element"
        case .screenOCR:
            return "ocr"
        case .unavailable:
            return "unavailable"
        }
    }

    private static func visualContextLogValue(_ visualContext: VisualContextSnapshot?) -> String {
        guard let visualContext else {
            return "none"
        }
        return visualContext.isEmpty ? "omitted-empty" : "included"
    }

    private static func clipboardContextLogValue(_ clipboardContext: ClipboardContextSnapshot?) -> String {
        guard let clipboardContext else {
            return "none"
        }
        return clipboardContext.isIncluded
            ? "included"
            : "omitted-\(clipboardContext.status.rawValue)"
    }

    private static func joinTitle(_ values: [String], fallback: String) -> String {
        values.isEmpty ? fallback : values.joined(separator: ", ")
    }

    private static func joinLogValue(_ values: [String], fallback: String) -> String {
        values.isEmpty ? fallback : values.joined(separator: ",")
    }
}

private struct SourceLabel {
    let title: String
    let logValue: String
}
