import Foundation

public struct CompletionRequest: Equatable, Sendable {
    public let contextID: UUID
    public let app: AppIdentity
    public let domain: String?
    public let prompt: String
    public let truncatedTextBeforeCursor: String
    public let allowedCaptureSources: Set<TextCaptureSource>
    public let model: String
    public let maxTokens: Int
    public let temperature: Double
    public let visualContext: VisualContextSnapshot?
    public let promptEchoCandidates: [String]

    public init(
        contextID: UUID,
        app: AppIdentity,
        domain: String?,
        prompt: String,
        truncatedTextBeforeCursor: String,
        allowedCaptureSources: Set<TextCaptureSource>,
        model: String,
        maxTokens: Int,
        temperature: Double,
        visualContext: VisualContextSnapshot? = nil,
        promptEchoCandidates: [String]
    ) {
        self.contextID = contextID
        self.app = app
        self.domain = domain
        self.prompt = prompt
        self.truncatedTextBeforeCursor = truncatedTextBeforeCursor
        self.allowedCaptureSources = allowedCaptureSources
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.visualContext = visualContext
        self.promptEchoCandidates = promptEchoCandidates
    }
}
