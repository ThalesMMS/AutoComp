import Foundation

public struct InputMethodState: Codable, Equatable, Sendable {
    public let isASCIICompatible: Bool
    public let isComposingText: Bool
    public let currentInputSourceID: String?

    public init(
        isASCIICompatible: Bool,
        isComposingText: Bool = false,
        currentInputSourceID: String? = nil
    ) {
        self.isASCIICompatible = isASCIICompatible
        self.isComposingText = isComposingText
        self.currentInputSourceID = currentInputSourceID
    }

    public static let asciiCompatible = InputMethodState(isASCIICompatible: true)

    public var allowsAutomaticSuggestions: Bool {
        isASCIICompatible && !isComposingText
    }

    public var shouldPassThroughSuggestionShortcuts: Bool {
        !isASCIICompatible || isComposingText
    }

    public var diagnosticSummary: String {
        if isComposingText {
            return "composing"
        }
        return isASCIICompatible ? "ASCII" : "non-ASCII"
    }
}
