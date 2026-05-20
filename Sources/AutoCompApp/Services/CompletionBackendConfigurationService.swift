import AutoCompCore
import Foundation

struct LocalLlamaRuntimeState: Equatable {
    var isAvailable: Bool
    var message: String

    static let unavailableInBuild = LocalLlamaRuntimeState(
        isAvailable: false,
        message: "Local runtime is unavailable in this app build."
    )

    static let available = LocalLlamaRuntimeState(
        isAvailable: true,
        message: "Local runtime is available."
    )
}

struct LocalLlamaDiagnostic: Equatable {
    var runtimeTitle: String
    var modelFileTitle: String
    var loadStateTitle: String
    var lastErrorTitle: String
    var fallbackTitle: String
    var memoryLimitTitle: String
    var isUsable: Bool
}

struct CompletionBackendSettings: Equatable {
    var engineKind: CompletionEngineKind
    var remoteBaseURL: String
    var remoteAPIKey: String
    var remoteModel: String
    var localModelPath: String
    var localMaxRAMBytes: UInt64
    var localRuntimeState: LocalLlamaRuntimeState
    var localLastError: String?
    var fallbackToRemoteOnLocalFailure: Bool
    var fallbackToRemoteOnAppleIntelligenceFailure: Bool

    init(
        engineKind: CompletionEngineKind = .remote,
        remoteBaseURL: String = "http://100.98.1.45:8000",
        remoteAPIKey: String = "",
        remoteModel: String = "Qwen/Qwen3.6-35B-A3B",
        localModelPath: String = CompletionBackendSettings.defaultLocalModelPath,
        localMaxRAMBytes: UInt64 = 6_442_450_944,
        localRuntimeState: LocalLlamaRuntimeState = .unavailableInBuild,
        localLastError: String? = nil,
        fallbackToRemoteOnLocalFailure: Bool = true,
        fallbackToRemoteOnAppleIntelligenceFailure: Bool = true
    ) {
        self.engineKind = engineKind
        self.remoteBaseURL = remoteBaseURL
        self.remoteAPIKey = remoteAPIKey
        self.remoteModel = remoteModel
        self.localModelPath = localModelPath
        self.localMaxRAMBytes = localMaxRAMBytes
        self.localRuntimeState = localRuntimeState
        self.localLastError = localLastError
        self.fallbackToRemoteOnLocalFailure = fallbackToRemoteOnLocalFailure
        self.fallbackToRemoteOnAppleIntelligenceFailure = fallbackToRemoteOnAppleIntelligenceFailure
    }

    var summary: String {
        switch engineKind {
        case .remote:
            return "Remote backend: \(remoteModel) at \(remoteBaseURL)"
        case .localLlama:
            let diagnostic = localDiagnostic()
            if diagnostic.isUsable {
                return "Local Llama backend: available at \(localModelPath)"
            }
            return "Local Llama backend unavailable: \(diagnostic.runtimeTitle); \(diagnostic.modelFileTitle)"
        case .appleIntelligence:
            return fallbackToRemoteOnAppleIntelligenceFailure
                ? "Apple Intelligence backend with remote fallback"
                : "Apple Intelligence backend without fallback"
        }
    }

    var remoteConfiguration: RemoteCompletionConfiguration {
        RemoteCompletionConfiguration(
            baseURL: remoteBaseURL,
            apiKey: remoteAPIKey,
            model: remoteModel
        )
    }

    var localConfiguration: LocalLlamaConfiguration {
        LocalLlamaConfiguration(
            modelPath: localModelPath,
            maxRAMBytes: localMaxRAMBytes
        )
    }

    func localDiagnostic(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> LocalLlamaDiagnostic {
        let modelExists = fileExists(localModelPath)
        let runtimeTitle = localRuntimeState.isAvailable ? "Available" : "Unavailable: \(localRuntimeState.message)"
        let modelFileTitle = modelExists ? "Found at \(localModelPath)" : "Missing at \(localModelPath)"
        let loadStateTitle = localRuntimeState.isAvailable && modelExists ? "Ready to load" : "Blocked"
        let lastErrorTitle: String
        if let localLastError, !localLastError.isEmpty {
            lastErrorTitle = localLastError
        } else {
            lastErrorTitle = "None"
        }
        let fallbackTitle = fallbackToRemoteOnLocalFailure ? "Remote fallback enabled" : "Remote fallback disabled"
        let memoryLimitTitle = ByteCountFormatter.string(
            fromByteCount: Int64(min(localMaxRAMBytes, UInt64(Int64.max))),
            countStyle: .memory
        )

        return LocalLlamaDiagnostic(
            runtimeTitle: runtimeTitle,
            modelFileTitle: modelFileTitle,
            loadStateTitle: loadStateTitle,
            lastErrorTitle: lastErrorTitle,
            fallbackTitle: fallbackTitle,
            memoryLimitTitle: memoryLimitTitle,
            isUsable: localRuntimeState.isAvailable && modelExists
        )
    }

    static var defaultLocalModelPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoComp", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("autocomp.gguf")
            .path
    }
}

struct CompletionBackendConfigurationService {
    private let defaults: UserDefaults
    private let keychainService: String
    private let keychainAccount: String
    private let defaultsPrefix = "completionBackend."

    init(
        defaults: UserDefaults = .standard,
        keychainService: String = "com.autocomp.backend",
        keychainAccount: String = "remote-api-key"
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    func load() -> CompletionBackendSettings {
        let values = loadValues()

        return CompletionBackendSettings(
            engineKind: CompletionEngineKind(rawValue: defaults.string(forKey: defaultsPrefix + "kind") ?? "") ?? .remote,
            remoteBaseURL: defaults.string(forKey: defaultsPrefix + "remoteBaseURL")
                ?? values["AUTOCOMP_REMOTE_BASE_URL"]
                ?? "http://100.98.1.45:8000",
            remoteAPIKey: loadRemoteAPIKey(defaultValue: values["AUTOCOMP_REMOTE_API_KEY"] ?? ""),
            remoteModel: defaults.string(forKey: defaultsPrefix + "remoteModel")
                ?? values["AUTOCOMP_REMOTE_MODEL"]
                ?? "Qwen/Qwen3.6-35B-A3B",
            localModelPath: defaults.string(forKey: defaultsPrefix + "localModelPath")
                ?? values["AUTOCOMP_LOCAL_MODEL_PATH"]
                ?? CompletionBackendSettings.defaultLocalModelPath,
            localMaxRAMBytes: loadUInt64(
                key: defaultsPrefix + "localMaxRAMBytes",
                environmentValue: values["AUTOCOMP_LOCAL_MAX_RAM_BYTES"],
                defaultValue: 6_442_450_944
            ),
            localRuntimeState: .unavailableInBuild,
            localLastError: defaults.string(forKey: defaultsPrefix + "localLastError"),
            fallbackToRemoteOnLocalFailure: loadBool(
                key: defaultsPrefix + "fallbackToRemoteOnLocalFailure",
                environmentValue: values["AUTOCOMP_LOCAL_FALLBACK_TO_REMOTE"],
                defaultValue: true
            ),
            fallbackToRemoteOnAppleIntelligenceFailure: loadBool(
                key: defaultsPrefix + "fallbackToRemoteOnAppleIntelligenceFailure",
                environmentValue: values["AUTOCOMP_APPLE_INTELLIGENCE_FALLBACK_TO_REMOTE"],
                defaultValue: true
            )
        )
    }

    func save(_ settings: CompletionBackendSettings) {
        defaults.set(settings.engineKind.rawValue, forKey: defaultsPrefix + "kind")
        defaults.set(settings.remoteBaseURL, forKey: defaultsPrefix + "remoteBaseURL")
        defaults.set(settings.remoteModel, forKey: defaultsPrefix + "remoteModel")
        defaults.set(settings.localModelPath, forKey: defaultsPrefix + "localModelPath")
        defaults.set(settings.localMaxRAMBytes, forKey: defaultsPrefix + "localMaxRAMBytes")
        if let localLastError = settings.localLastError, !localLastError.isEmpty {
            defaults.set(localLastError, forKey: defaultsPrefix + "localLastError")
        } else {
            defaults.removeObject(forKey: defaultsPrefix + "localLastError")
        }
        defaults.set(settings.fallbackToRemoteOnLocalFailure, forKey: defaultsPrefix + "fallbackToRemoteOnLocalFailure")
        defaults.set(settings.fallbackToRemoteOnAppleIntelligenceFailure, forKey: defaultsPrefix + "fallbackToRemoteOnAppleIntelligenceFailure")
        saveRemoteAPIKey(settings.remoteAPIKey)
    }

    private func loadUInt64(key: String, environmentValue: String?, defaultValue: UInt64) -> UInt64 {
        if let object = defaults.object(forKey: key) as? NSNumber {
            return object.uint64Value
        }

        if let environmentValue,
           let value = UInt64(environmentValue) {
            return value
        }

        return defaultValue
    }

    private func loadBool(key: String, environmentValue: String?, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }

        if let environmentValue {
            switch environmentValue.lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        return defaultValue
    }

    private func loadRemoteAPIKey(defaultValue: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
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
        var values = ProcessInfo.processInfo.environment

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
