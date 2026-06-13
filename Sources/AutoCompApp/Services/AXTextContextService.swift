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
    case interactionPipelineSuspended

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
        case .interactionPipelineSuspended:
            return "Interaction pipeline is paused."
        }
    }
}
