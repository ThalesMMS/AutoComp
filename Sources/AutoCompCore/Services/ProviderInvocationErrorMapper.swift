import Foundation

/// Maps provider/network errors into pipeline discard reasons.
///
/// This centralizes the translation of various provider implementations' errors
/// into a small set of structured, user/debuggable discard reasons.
public struct ProviderInvocationErrorMapper: Sendable {
    public init() {}

    public func map(_ error: Error) -> SuggestionPipeline.DiscardReason {
        if error is CancellationError {
            return .cancelled
        }

        if let remote = error as? RemoteCompletionError {
            return map(remote)
        }

        if let issueCarrier = error as? BackendConnectivityIssueProviding {
            return map(issueCarrier.connectivityIssue)
        }

        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return .init(kind: .error, message: message)
    }

    private func map(_ error: RemoteCompletionError) -> SuggestionPipeline.DiscardReason {
        switch error.issue {
        case .emptyResponse:
            return .init(kind: .emptyResponse, message: error.issue.logValue, backendIssue: error.issue)
        default:
            return .init(kind: .error, message: error.issue.logValue, backendIssue: error.issue)
        }
    }

    private func map(_ issue: BackendConnectivityIssue) -> SuggestionPipeline.DiscardReason {
        switch issue {
        case .emptyResponse:
            return .init(kind: .emptyResponse, message: issue.logValue, backendIssue: issue)
        default:
            return .init(kind: .error, message: issue.logValue, backendIssue: issue)
        }
    }
}

/// Optional protocol for provider implementations to expose a domain issue.
public protocol BackendConnectivityIssueProviding {
    var connectivityIssue: BackendConnectivityIssue { get }
}
