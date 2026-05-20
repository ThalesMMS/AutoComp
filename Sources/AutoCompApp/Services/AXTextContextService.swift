import ApplicationServices
import AppKit
import AutoCompCore
import Foundation

enum AXTextContextError: LocalizedError {
    case accessibilityNotTrusted
    case noFrontmostApplication
    case noFocusedElement
    case secureOrUnsupportedField
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required for autocomplete."
        case .noFrontmostApplication:
            return "No frontmost app is available."
        case .noFocusedElement:
            return "No focused text field is available."
        case .secureOrUnsupportedField:
            return "The focused field is secure or unsupported."
        case .noReadableText:
            return "The focused text field did not expose readable text."
        }
    }
}

final class AXTextContextService: TextContextProvider, @unchecked Sendable {
    private let focusTrackingModel: FocusTrackingModel

    init(
        axHelper: AXHelper = AXHelper(),
        browserResolver: BrowserContextResolver = BrowserContextResolver(),
        screenOCRGeometryFallbackResolver: ScreenOCRGeometryFallbackResolver = ScreenOCRGeometryFallbackResolver()
    ) {
        self.focusTrackingModel = FocusTrackingModel(
            axHelper: axHelper,
            focusSnapshotResolver: FocusSnapshotResolver(
                axHelper: axHelper,
                browserResolver: browserResolver
            ),
            textGeometryResolver: AXTextGeometryResolver(axHelper: axHelper),
            screenOCRGeometryFallbackResolver: screenOCRGeometryFallbackResolver
        )
    }

    func currentContext() async throws -> TextContext {
        try await focusTrackingModel.currentContext()
    }
}
