import AutoCompCore
import Foundation

struct CompletionBackendSettings: Equatable {
    var remoteBaseURL: String
    var remoteAPIKey: String
    var remoteModel: String

    init(
        remoteBaseURL: String = "http://127.0.0.1:8000",
        remoteAPIKey: String = "",
        remoteModel: String = "Qwen/Qwen3.6-35B-A3B"
    ) {
        self.remoteBaseURL = remoteBaseURL
        self.remoteAPIKey = remoteAPIKey
        self.remoteModel = remoteModel
    }

    var summary: String {
        "Remote backend: \(remoteModel) at \(remoteBaseURL)"
    }

    var remoteConfiguration: RemoteCompletionConfiguration {
        RemoteCompletionConfiguration(
            baseURL: remoteBaseURL,
            apiKey: remoteAPIKey,
            model: remoteModel
        )
    }
}

struct CompletionBackendConfigurationService {
    private let defaults: UserDefaults
    private let defaultsPrefix = "completionBackend."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CompletionBackendSettings {
        let values = loadValues()

        return CompletionBackendSettings(
            remoteBaseURL: defaults.string(forKey: defaultsPrefix + "remoteBaseURL")
                ?? values["AUTOCOMP_REMOTE_BASE_URL"]
                ?? "http://127.0.0.1:8000",
            remoteAPIKey: loadRemoteAPIKey(defaultValue: values["AUTOCOMP_REMOTE_API_KEY"] ?? ""),
            remoteModel: defaults.string(forKey: defaultsPrefix + "remoteModel")
                ?? values["AUTOCOMP_REMOTE_MODEL"]
                ?? "Qwen/Qwen3.6-35B-A3B"
        )
    }

    func save(_ settings: CompletionBackendSettings) {
        defaults.set("remote", forKey: defaultsPrefix + "kind")
        defaults.set(settings.remoteBaseURL, forKey: defaultsPrefix + "remoteBaseURL")
        defaults.set(settings.remoteModel, forKey: defaultsPrefix + "remoteModel")
        saveRemoteAPIKey(settings.remoteAPIKey)
    }

    private func loadRemoteAPIKey(defaultValue: String) -> String {
        let service = "com.autocomp.backend"
        let account = "remote-api-key"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            return defaultValue
        }

        return key
    }

    private func saveRemoteAPIKey(_ key: String) {
        let service = "com.autocomp.backend"
        let account = "remote-api-key"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        guard !key.isEmpty, let data = key.data(using: .utf8) else {
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadValues() -> [String: String] {
        var values = [String: String]()

        // First, load from .env files (lower priority)
        for url in envFileCandidates() {
            guard let data = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            for line in data.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                    continue
                }

                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                values[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        // Then, overlay system environment variables (higher priority)
        for (key, value) in ProcessInfo.processInfo.environment {
            values[key] = value
        }

        return values
    }

    private func envFileCandidates() -> [URL] {
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("autocomp.env"))
        }

        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env.local"))

        return candidates
    }
}
