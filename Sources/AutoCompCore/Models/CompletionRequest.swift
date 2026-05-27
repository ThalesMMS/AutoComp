import Foundation

public enum CompletionRequestMode: String, Codable, Equatable, Sendable {
    case continuation
    case fillInMiddle
}

public struct CompletionRequest: Equatable, Sendable {
    public let contextID: UUID
    public let app: AppIdentity
    public let domain: String?
    public let prompt: String
    public let mode: CompletionRequestMode
    public let truncatedTextBeforeCursor: String
    public let truncatedTextAfterCursor: String?
    public let truncatedSelectedText: String?
    public let truncatedFullTextWindow: String?
    public let fimSuffixInjected: Bool
    public let allowedCaptureSources: Set<TextCaptureSource>
    public let model: String
    public let maxTokens: Int
    public let temperature: Double
    public let visualContext: VisualContextSnapshot?
    public let clipboardContext: ClipboardContextSnapshot?
    public let promptEchoCandidates: [String]

    public init(
        contextID: UUID,
        app: AppIdentity,
        domain: String?,
        prompt: String,
        mode: CompletionRequestMode = .continuation,
        truncatedTextBeforeCursor: String,
        truncatedTextAfterCursor: String? = nil,
        truncatedSelectedText: String? = nil,
        truncatedFullTextWindow: String? = nil,
        fimSuffixInjected: Bool = false,
        allowedCaptureSources: Set<TextCaptureSource>,
        model: String,
        maxTokens: Int,
        temperature: Double,
        visualContext: VisualContextSnapshot? = nil,
        clipboardContext: ClipboardContextSnapshot? = nil,
        promptEchoCandidates: [String]
    ) {
        self.contextID = contextID
        self.app = app
        self.domain = domain
        self.prompt = prompt
        self.mode = mode
        self.truncatedTextBeforeCursor = truncatedTextBeforeCursor
        self.truncatedTextAfterCursor = truncatedTextAfterCursor
        self.truncatedSelectedText = truncatedSelectedText
        self.truncatedFullTextWindow = truncatedFullTextWindow
        self.fimSuffixInjected = fimSuffixInjected
        self.allowedCaptureSources = allowedCaptureSources
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.visualContext = visualContext
        self.clipboardContext = clipboardContext
        self.promptEchoCandidates = promptEchoCandidates
    }
}
