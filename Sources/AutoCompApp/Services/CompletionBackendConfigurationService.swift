import AutoCompCore
import Foundation

#if AUTOCOMP_LLAMA_RUNTIME
import AutoCompLlamaRuntime
#endif

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

struct AppleIntelligenceDiagnostic: Equatable {
    var availabilityTitle: String
    var requirementTitle: String
    var fallbackTitle: String
    var isUsable: Bool
}

struct CompletionBackendSettings: Equatable {
    static let defaultMultiSuggestionEnabled = false

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
    var multiSuggestionEnabled: Bool
    var stopSequences: CompletionStopSequences

    init(
        engineKind: CompletionEngineKind = .remote,
        remoteBaseURL: String = "http://100.98.1.45:8000",
        remoteAPIKey: String = "",
        remoteModel: String = "default",
        localModelPath: String = CompletionBackendSettings.defaultLocalModelPath,
        localMaxRAMBytes: UInt64 = 6_442_450_944,
        localRuntimeState: LocalLlamaRuntimeState = .unavailableInBuild,
        localLastError: String? = nil,
        fallbackToRemoteOnLocalFailure: Bool = false,
        fallbackToRemoteOnAppleIntelligenceFailure: Bool = false,
        multiSuggestionEnabled: Bool = CompletionBackendSettings.defaultMultiSuggestionEnabled,
        stopSequences: CompletionStopSequences = .conservativeDefault
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
        self.multiSuggestionEnabled = multiSuggestionEnabled
        self.stopSequences = stopSequences
    }

    var summary: String {
        backendSummary()
    }

    func backendSummary(
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        appleAvailability: AppleFoundationModelAvailability = SystemAppleFoundationModelBackend.availability()
    ) -> String {
        switch engineKind {
        case .remote:
            return "Remote backend: \(remoteModel) at \(remoteBaseURL)"
        case .localLlama:
            let diagnostic = localDiagnostic(fileExists: fileExists)
            if diagnostic.isUsable {
                return fallbackToRemoteOnLocalFailure
                    ? "Local Llama backend available with remote fallback at \(localModelPath)"
                    : "Local Llama backend available without fallback at \(localModelPath)"
            }
            return fallbackToRemoteOnLocalFailure
                ? "Local Llama backend unavailable: \(diagnostic.runtimeTitle); \(diagnostic.modelFileTitle); remote fallback enabled"
                : "Local Llama backend unavailable: \(diagnostic.runtimeTitle); \(diagnostic.modelFileTitle); remote fallback disabled"
        case .appleIntelligence:
            let diagnostic = appleIntelligenceDiagnostic(availability: appleAvailability)
            if diagnostic.isUsable {
                return fallbackToRemoteOnAppleIntelligenceFailure
                    ? "Apple Intelligence backend available with remote fallback"
                    : "Apple Intelligence backend available without fallback"
            }
            return fallbackToRemoteOnAppleIntelligenceFailure
                ? "Apple Intelligence backend unavailable: \(diagnostic.requirementTitle); remote fallback enabled"
                : "Apple Intelligence backend unavailable: \(diagnostic.requirementTitle); remote fallback disabled"
        }
    }

    var remoteConfiguration: RemoteCompletionConfiguration {
        RemoteCompletionConfiguration(
            baseURL: remoteBaseURL,
            apiKey: remoteAPIKey,
            model: remoteModel,
            stopSequences: stopSequences
        )
    }

    var stopSequenceSummaryTitle: String {
        "\(stopSequences.continuation.count) continuation, \(stopSequences.fillInMiddle.count) FIM"
    }

    var stopSequenceBehaviorTitle: String {
        switch engineKind {
        case .remote:
            return "Sent as OpenAI-compatible stop sequences."
        case .localLlama:
            return "Applied in the local generation loop when the runtime is available."
        case .appleIntelligence:
            return "Post-generation trimming fallback; Apple Intelligence does not expose stop sequences."
        }
    }

    var requestDestinationTitle: String {
        switch engineKind {
        case .remote:
            return "Remote: \(remoteModel) at \(remoteBaseURL)"
        case .localLlama:
            guard !localModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Local in-process: no model selected"
            }
            let modelFileName = URL(fileURLWithPath: localModelPath).lastPathComponent
            return "Local in-process: \(modelFileName.isEmpty ? localConfiguration.modelName : modelFileName)"
        case .appleIntelligence:
            return "Apple Intelligence on this Mac"
        }
    }

    var dataLeavesDeviceTitle: String {
        dataLeavesDeviceTitle()
    }

    func dataLeavesDeviceTitle(
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        appleAvailability: AppleFoundationModelAvailability = SystemAppleFoundationModelBackend.availability()
    ) -> String {
        switch engineKind {
        case .remote:
            return "Yes, autocomplete text is sent to \(remoteBaseURL)."
        case .localLlama:
            if fallbackToRemoteOnLocalFailure {
                return "Local first; text may be sent to \(remoteBaseURL) after a local failure."
            }
            return localDiagnostic(fileExists: fileExists).isUsable
                ? "No, local completion requests stay on this Mac."
                : "No remote endpoint; local completion is blocked until runtime and model prerequisites are met."
        case .appleIntelligence:
            if fallbackToRemoteOnAppleIntelligenceFailure {
                return "Apple first; text may be sent to \(remoteBaseURL) after an Apple Intelligence failure."
            }
            return appleIntelligenceDiagnostic(availability: appleAvailability).isUsable
                ? "No remote endpoint while Apple Intelligence succeeds."
                : "No remote endpoint; Apple Intelligence is unavailable on this Mac."
        }
    }

    var remoteFallbackTitle: String {
        switch engineKind {
        case .remote:
            return "Not applicable because the remote backend is selected."
        case .localLlama:
            return fallbackToRemoteOnLocalFailure ? "Enabled after local failure" : "Disabled"
        case .appleIntelligence:
            return fallbackToRemoteOnAppleIntelligenceFailure ? "Enabled after Apple Intelligence failure" : "Disabled"
        }
    }

    var remoteFallbackWarning: String? {
        switch engineKind {
        case .remote:
            return nil
        case .localLlama where fallbackToRemoteOnLocalFailure:
            return "Remote fallback is enabled: if local completion fails, autocomplete text may be sent to \(remoteBaseURL)."
        case .appleIntelligence where fallbackToRemoteOnAppleIntelligenceFailure:
            return "Remote fallback is enabled: if Apple Intelligence fails, autocomplete text may be sent to \(remoteBaseURL)."
        case .localLlama, .appleIntelligence:
            return nil
        }
    }

    func remoteBackendExposureTitle(sourceEnabled: Bool) -> String {
        guard sourceEnabled else {
            return "No; source is off."
        }

        switch engineKind {
        case .remote:
            return "Yes, sent to \(remoteBaseURL)."
        case .localLlama:
            return fallbackToRemoteOnLocalFailure
                ? "Only after local failure fallback to \(remoteBaseURL)."
                : "No remote backend."
        case .appleIntelligence:
            return fallbackToRemoteOnAppleIntelligenceFailure
                ? "Only after Apple Intelligence fallback to \(remoteBaseURL)."
                : "No remote backend."
        }
    }

    var localConfiguration: LocalLlamaConfiguration {
        LocalLlamaConfiguration(
            modelPath: localModelPath,
            maxRAMBytes: localMaxRAMBytes,
            stopSequences: stopSequences
        )
    }

    func localDiagnostic(
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        loadStatus: LocalLlamaRuntimeStatus = .unloaded
    ) -> LocalLlamaDiagnostic {
        let hasModelPath = !localModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelExists = hasModelPath && fileExists(localModelPath)
        let runtimeTitle = localRuntimeState.isAvailable ? "Available" : "Unavailable: \(localRuntimeState.message)"
        let modelFileTitle: String
        if !hasModelPath {
            modelFileTitle = "No model selected"
        } else {
            modelFileTitle = modelExists ? "Found at \(localModelPath)" : "Missing at \(localModelPath)"
        }
        let loadStateTitle: String
        if localRuntimeState.isAvailable && modelExists {
            loadStateTitle = loadStatus.applies(to: localModelPath)
                ? loadStatus.state.title
                : LocalLlamaRuntimeLoadState.unloaded.title
        } else {
            loadStateTitle = "Blocked"
        }
        let lastErrorTitle: String
        if let localLastError, !localLastError.isEmpty {
            lastErrorTitle = localLastError
        } else if loadStatus.applies(to: localModelPath),
                  loadStatus.state == .failed,
                  let message = loadStatus.message,
                  !message.isEmpty {
            lastErrorTitle = message
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

    func appleIntelligenceDiagnostic(
        availability: AppleFoundationModelAvailability = SystemAppleFoundationModelBackend.availability()
    ) -> AppleIntelligenceDiagnostic {
        AppleIntelligenceDiagnostic(
            availabilityTitle: availability.statusTitle,
            requirementTitle: availability.detail,
            fallbackTitle: fallbackToRemoteOnAppleIntelligenceFailure
                ? "Remote fallback enabled"
                : "Remote fallback disabled",
            isUsable: availability.isAvailable
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

private extension LocalLlamaRuntimeStatus {
    func applies(to modelPath: String) -> Bool {
        self.modelPath == nil || self.modelPath == modelPath
    }
}

struct CompletionBackendConfigurationService {
    private let defaults: UserDefaults
    private let mirroredDefaults: [UserDefaults]
    private let keychainService: String
    private let keychainAccount: String
    private let defaultsPrefix = "completionBackend."

    init(
        defaults: UserDefaults = .standard,
        mirroredDefaults: [UserDefaults]? = nil,
        keychainService: String = "com.autocomp.backend",
        keychainAccount: String = "remote-api-key"
    ) {
        self.defaults = defaults
        self.mirroredDefaults = mirroredDefaults ?? Self.defaultMirroredDefaults(for: defaults)
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    func load(
        localRuntimeState: LocalLlamaRuntimeState = CompletionBackendConfigurationService.localRuntimeState(),
        values overrideValues: [String: String]? = nil
    ) -> CompletionBackendSettings {
        let values = overrideValues ?? loadValues()

        return CompletionBackendSettings(
            engineKind: CompletionEngineKind(rawValue: string(forKey: defaultsPrefix + "kind") ?? "") ?? .remote,
            remoteBaseURL: string(forKey: defaultsPrefix + "remoteBaseURL")
                ?? values["AUTOCOMP_REMOTE_BASE_URL"]
                ?? "http://100.98.1.45:8000",
            remoteAPIKey: loadRemoteAPIKey(defaultValue: values["AUTOCOMP_REMOTE_API_KEY"] ?? ""),
            remoteModel: string(forKey: defaultsPrefix + "remoteModel")
                ?? values["AUTOCOMP_REMOTE_MODEL"]
                ?? "default",
            localModelPath: string(forKey: defaultsPrefix + "localModelPath")
                ?? values["AUTOCOMP_LOCAL_MODEL_PATH"]
                ?? CompletionBackendSettings.defaultLocalModelPath,
            localMaxRAMBytes: loadUInt64(
                key: defaultsPrefix + "localMaxRAMBytes",
                environmentValue: values["AUTOCOMP_LOCAL_MAX_RAM_BYTES"],
                defaultValue: 6_442_450_944
            ),
            localRuntimeState: localRuntimeState,
            localLastError: string(forKey: defaultsPrefix + "localLastError"),
            fallbackToRemoteOnLocalFailure: loadBool(
                key: defaultsPrefix + "fallbackToRemoteOnLocalFailure",
                environmentValue: values["AUTOCOMP_LOCAL_FALLBACK_TO_REMOTE"],
                defaultValue: false
            ),
            fallbackToRemoteOnAppleIntelligenceFailure: loadBool(
                key: defaultsPrefix + "fallbackToRemoteOnAppleIntelligenceFailure",
                environmentValue: values["AUTOCOMP_APPLE_INTELLIGENCE_FALLBACK_TO_REMOTE"],
                defaultValue: false
            ),
            multiSuggestionEnabled: loadBool(
                key: defaultsPrefix + "multiSuggestionEnabled",
                environmentValue: values["AUTOCOMP_DEBUG_MULTI_SUGGESTION_ENABLED"]
                    ?? values["AUTOCOMP_MULTI_SUGGESTION_ENABLED"],
                defaultValue: CompletionBackendSettings.defaultMultiSuggestionEnabled
            ),
            stopSequences: loadStopSequences(values: values)
        )
    }

    static func localRuntimeState() -> LocalLlamaRuntimeState {
        #if AUTOCOMP_LLAMA_RUNTIME
        guard LlamaCppRuntimeBackend.runtimeSystemInfo() != "unavailable" else {
            return LocalLlamaRuntimeState(
                isAvailable: false,
                message: "Local runtime libraries are unavailable."
            )
        }
        return .available
        #else
        return .unavailableInBuild
        #endif
    }

    func save(_ settings: CompletionBackendSettings) {
        set(settings.engineKind.rawValue, forKey: defaultsPrefix + "kind")
        set(settings.remoteBaseURL, forKey: defaultsPrefix + "remoteBaseURL")
        set(settings.remoteModel, forKey: defaultsPrefix + "remoteModel")
        set(settings.localModelPath, forKey: defaultsPrefix + "localModelPath")
        set(settings.localMaxRAMBytes, forKey: defaultsPrefix + "localMaxRAMBytes")
        if let localLastError = settings.localLastError, !localLastError.isEmpty {
            set(localLastError, forKey: defaultsPrefix + "localLastError")
        } else {
            removeObject(forKey: defaultsPrefix + "localLastError")
        }
        set(settings.fallbackToRemoteOnLocalFailure, forKey: defaultsPrefix + "fallbackToRemoteOnLocalFailure")
        set(settings.fallbackToRemoteOnAppleIntelligenceFailure, forKey: defaultsPrefix + "fallbackToRemoteOnAppleIntelligenceFailure")
        set(settings.multiSuggestionEnabled, forKey: defaultsPrefix + "multiSuggestionEnabled")
        set(settings.stopSequences.continuation, forKey: defaultsPrefix + "stopSequences.continuation")
        set(settings.stopSequences.fillInMiddle, forKey: defaultsPrefix + "stopSequences.fillInMiddle")
        synchronize()
        saveRemoteAPIKey(settings.remoteAPIKey)
    }

    private func loadStopSequences(values: [String: String]) -> CompletionStopSequences {
        CompletionStopSequences(
            continuation: loadStopSequenceList(
                key: defaultsPrefix + "stopSequences.continuation",
                environmentValue: values["AUTOCOMP_STOP_SEQUENCES_CONTINUATION"],
                defaultValue: CompletionStopSequences.conservativeDefault.continuation
            ),
            fillInMiddle: loadStopSequenceList(
                key: defaultsPrefix + "stopSequences.fillInMiddle",
                environmentValue: values["AUTOCOMP_STOP_SEQUENCES_FIM"],
                defaultValue: CompletionStopSequences.conservativeDefault.fillInMiddle
            )
        )
    }

    private func loadStopSequenceList(
        key: String,
        environmentValue: String?,
        defaultValue: [String]
    ) -> [String] {
        if let stored = object(forKey: key) as? [String] {
            return stored
        }

        if let environmentValue {
            return environmentValue
                .components(separatedBy: "||")
                .map(unescapedStopSequence)
        }

        return defaultValue
    }

    private func unescapedStopSequence(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private func loadUInt64(key: String, environmentValue: String?, defaultValue: UInt64) -> UInt64 {
        if let object = object(forKey: key) as? NSNumber {
            return object.uint64Value
        }

        if let environmentValue,
           let value = UInt64(environmentValue) {
            return value
        }

        return defaultValue
    }

    private func loadBool(key: String, environmentValue: String?, defaultValue: Bool) -> Bool {
        if object(forKey: key) != nil {
            return bool(forKey: key)
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

    private var readableDefaults: [UserDefaults] {
        [defaults] + mirroredDefaults
    }

    private var writableDefaults: [UserDefaults] {
        [defaults] + mirroredDefaults
    }

    private func string(forKey key: String) -> String? {
        readableDefaults.lazy.compactMap { $0.string(forKey: key) }.first
    }

    private func object(forKey key: String) -> Any? {
        readableDefaults.lazy.compactMap { $0.object(forKey: key) }.first
    }

    private func bool(forKey key: String) -> Bool {
        readableDefaults.first { $0.object(forKey: key) != nil }?.bool(forKey: key) ?? false
    }

    private func set(_ value: Any?, forKey key: String) {
        for defaults in writableDefaults {
            defaults.set(value, forKey: key)
        }
    }

    private func removeObject(forKey key: String) {
        for defaults in writableDefaults {
            defaults.removeObject(forKey: key)
        }
    }

    private func synchronize() {
        for defaults in writableDefaults {
            defaults.synchronize()
        }
    }

    private static func defaultMirroredDefaults(for defaults: UserDefaults) -> [UserDefaults] {
        guard defaults === UserDefaults.standard else {
            return []
        }

        return [
            UserDefaults(suiteName: "com.autocomp.AutoComp"),
            UserDefaults(suiteName: "AutoComp")
        ]
        .compactMap(\.self)
        .filter { $0 !== defaults }
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
