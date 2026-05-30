import Foundation

/// A predefined remote backend endpoint configuration.
///
/// These presets are intended to help users quickly choose a common local server setup.
///
/// - Important: Matching is intentionally strict. A preset only matches when the stored base URL
///   string is exactly equal to the preset's `defaultBaseURL`.
public enum RemoteEndpointPreset: String, CaseIterable, Identifiable, Sendable {
    case lmStudio
    case ollama
    case llamaCpp
    case vLLMLocalAI
    case custom

    public var id: String { rawValue }

    /// Display name intended for Settings UI.
    public var title: String {
        switch self {
        case .lmStudio:
            return "LM Studio"
        case .ollama:
            return "Ollama"
        case .llamaCpp:
            return "llama.cpp server"
        case .vLLMLocalAI:
            return "vLLM / LocalAI"
        case .custom:
            return "Custom"
        }
    }

    /// The default base URL string for this preset.
    ///
    /// Returns `nil` for `.custom`.
    public var defaultBaseURL: String? {
        switch self {
        case .lmStudio:
            return "http://127.0.0.1:1234"
        case .ollama:
            return "http://127.0.0.1:11434"
        case .llamaCpp:
            return "http://127.0.0.1:8080"
        case .vLLMLocalAI:
            return "http://127.0.0.1:8000"
        case .custom:
            return nil
        }
    }

    /// Returns whether this preset matches the provided base URL string.
    ///
    /// Matching uses exact string equality.
    public func matches(baseURL: String) -> Bool {
        guard let defaultBaseURL else {
            return false
        }
        return defaultBaseURL == baseURL
    }

    /// Returns the preset that matches a stored base URL string.
    ///
    /// If no preset matches exactly, returns `.custom`.
    public static func preset(forBaseURL baseURL: String) -> RemoteEndpointPreset {
        allCases.first(where: { $0.matches(baseURL: baseURL) }) ?? .custom
    }
}
