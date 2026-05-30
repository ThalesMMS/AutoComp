import AutoCompCore
import Foundation

struct RemoteCompletionConsentRequirement: Identifiable, Equatable {
    let scope: RemoteCompletionConsentScope
    let title: String
    let detail: String
    let buttonTitle: String

    var id: RemoteCompletionConsentScope {
        scope
    }
}

struct RemoteCompletionConsentPolicy: RemoteCompletionConsentChecking {
    let store: RemoteCompletionConsentStore
    let remoteBaseURL: String

    func hasConsent(for scope: RemoteCompletionConsentScope) -> Bool {
        store.hasConsent(for: scope, remoteBaseURL: remoteBaseURL)
    }
}

final class RemoteCompletionConsentStore: @unchecked Sendable {
    private struct State: Codable, Equatable {
        var remoteBackendEndpoint: String?
        var remoteFallbackEndpoint: String?
    }

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "remoteCompletionConsent"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func hasConsent(
        for scope: RemoteCompletionConsentScope,
        remoteBaseURL: String
    ) -> Bool {
        endpoint(for: scope, in: load()) == Self.normalizedEndpoint(remoteBaseURL)
    }

    func grantConsent(
        for scope: RemoteCompletionConsentScope,
        remoteBaseURL: String
    ) {
        var state = load()
        setEndpoint(Self.normalizedEndpoint(remoteBaseURL), for: scope, in: &state)
        save(state)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    static func destinationKindTitle(for remoteBaseURL: String) -> String {
        guard let host = URLComponents(string: remoteBaseURL)
            .flatMap(\.host)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !host.isEmpty else {
            return "Unknown endpoint"
        }

        if isLoopback(host) {
            return "Local on this Mac"
        }
        if host.hasSuffix(".local") || isPrivateNetworkAddress(host) {
            return "LAN/private network"
        }
        return "Cloud or public internet"
    }

    static func normalizedEndpoint(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path.count > 1 {
            components.path = components.path.trimmingTrailingSlashes()
        }
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? trimmed
    }

    private func load() -> State {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func endpoint(
        for scope: RemoteCompletionConsentScope,
        in state: State
    ) -> String? {
        switch scope {
        case .remoteBackend:
            return state.remoteBackendEndpoint
        case .remoteFallback:
            return state.remoteFallbackEndpoint
        }
    }

    private func setEndpoint(
        _ endpoint: String,
        for scope: RemoteCompletionConsentScope,
        in state: inout State
    ) {
        switch scope {
        case .remoteBackend:
            state.remoteBackendEndpoint = endpoint
        case .remoteFallback:
            state.remoteFallbackEndpoint = endpoint
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "::1"
            || host.hasPrefix("127.")
    }

    private static func isPrivateNetworkAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        if octets[0] == 10 || octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }
        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return true
        }
        return octets[0] == 169 && octets[1] == 254
    }
}

extension CompletionBackendSettings {
    var remoteConsentRequirements: [RemoteCompletionConsentRequirement] {
        switch engineKind {
        case .remote:
            return [
                RemoteCompletionConsentRequirement(
                    scope: .remoteBackend,
                    title: "Remote completion",
                    detail: "Text from the active field may be sent to \(remoteBaseURL) for completion.",
                    buttonTitle: "Allow Remote Completion"
                )
            ]
        case .localLlama where fallbackToRemoteOnLocalFailure:
            return [
                RemoteCompletionConsentRequirement(
                    scope: .remoteFallback,
                    title: "Remote fallback",
                    detail: "Text from the active field may be sent to \(remoteBaseURL) after local completion fails.",
                    buttonTitle: "Allow Remote Fallback"
                )
            ]
        case .appleIntelligence where fallbackToRemoteOnAppleIntelligenceFailure:
            return [
                RemoteCompletionConsentRequirement(
                    scope: .remoteFallback,
                    title: "Remote fallback",
                    detail: "Text from the active field may be sent to \(remoteBaseURL) after Apple Intelligence fails.",
                    buttonTitle: "Allow Remote Fallback"
                )
            ]
        case .localLlama:
            return []
        case .appleIntelligence:
            return []
        }
    }

    var remoteConsentLocalOnlyDescription: String {
        switch engineKind {
        case .remote:
            return ""
        case .localLlama:
            return "Local Llama is selected without remote fallback. Completion text stays on this Mac."
        case .appleIntelligence:
            return "Apple Intelligence is selected without remote fallback. No remote endpoint is used for completion."
        }
    }

    var remoteConsentEndpointKindTitle: String {
        RemoteCompletionConsentStore.destinationKindTitle(for: remoteBaseURL)
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var value = self
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
