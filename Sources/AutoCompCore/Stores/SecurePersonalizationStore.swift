import CryptoKit
import Foundation
import Security

public enum SecurePersonalizationStoreError: Error, Equatable {
    case keychain(OSStatus)
    case encryptionFailed
    case decryptionFailed
}

public struct PersonalizationSample: Codable, Equatable, Sendable {
    public let excerpt: String
    public let appBundleID: String
    public let domain: String?
    public let languageHint: String?
    public let createdAt: Date

    public init(
        excerpt: String,
        appBundleID: String,
        domain: String?,
        languageHint: String?,
        createdAt: Date
    ) {
        self.excerpt = excerpt
        self.appBundleID = appBundleID
        self.domain = domain
        self.languageHint = languageHint
        self.createdAt = createdAt
    }
}

public struct PersonalizationStoreSummary: Equatable, Sendable {
    public let sampleCount: Int
    public let newestSampleDate: Date?

    public init(sampleCount: Int, newestSampleDate: Date?) {
        self.sampleCount = sampleCount
        self.newestSampleDate = newestSampleDate
    }

    public static let empty = PersonalizationStoreSummary(sampleCount: 0, newestSampleDate: nil)
}

public final class SecurePersonalizationStore: @unchecked Sendable {
    public static let defaultMaxStoredSamples = 200
    public static let defaultMaxExcerptCharacters = 280

    private let directory: URL
    private let service: String
    private let account: String

    public init(
        directory: URL,
        service: String = "com.autocomp.personalization",
        account: String = "local-profile-key"
    ) {
        self.directory = directory
        self.service = service
        self.account = account
    }

    public func append(_ text: String, appBundleID: String, domain: String?) throws {
        try appendSample(
            excerpt: text,
            appBundleID: appBundleID,
            domain: domain,
            languageHint: nil,
            createdAt: Date()
        )
    }

    @discardableResult
    public func appendSample(
        excerpt: String,
        appBundleID: String,
        domain: String?,
        languageHint: String?,
        createdAt: Date,
        maxStoredSamples: Int = SecurePersonalizationStore.defaultMaxStoredSamples,
        maxExcerptCharacters: Int = SecurePersonalizationStore.defaultMaxExcerptCharacters
    ) throws -> PersonalizationSample {
        let sample = PersonalizationSample(
            excerpt: String(excerpt.prefix(max(0, maxExcerptCharacters))),
            appBundleID: appBundleID,
            domain: domain.flatMap(DomainNormalization.canonicalDomainString(from:)),
            languageHint: normalizedLanguageHint(languageHint),
            createdAt: createdAt
        )
        let samples = try deduplicatedSamples(appending: sample, maxStoredSamples: maxStoredSamples)
        try writeSamples(samples)
        return sample
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try deleteKey()
    }

    public func recordCount() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "record" }.count
    }

    public func samples(limit: Int = Int.max) throws -> [PersonalizationSample] {
        let samples = try readSamples()
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.excerpt < rhs.excerpt
                }
                return lhs.createdAt > rhs.createdAt
            }
        return Array(samples.prefix(max(0, limit)))
    }

    public func promptSamples(
        appBundleID: String,
        domain: String?,
        languageHint: String?,
        limit: Int
    ) throws -> [PersonalizationSample] {
        let canonicalDomain = domain.flatMap(DomainNormalization.canonicalDomainString(from:))
        let normalizedLanguageHint = normalizedLanguageHint(languageHint)

        let scoped = try samples().filter { sample in
            guard sample.appBundleID == appBundleID else {
                return false
            }

            if canonicalDomain != nil {
                return sample.domain == canonicalDomain
            }

            return sample.domain == nil
        }

        let ranked = scoped.sorted { lhs, rhs in
            let lhsRank = sampleRank(lhs, languageHint: normalizedLanguageHint)
            let rhsRank = sampleRank(rhs, languageHint: normalizedLanguageHint)
            if lhsRank == rhsRank {
                return lhs.createdAt > rhs.createdAt
            }
            return lhsRank > rhsRank
        }

        return Array(ranked.prefix(max(0, limit)))
    }

    public func summary() -> PersonalizationStoreSummary {
        guard let samples = try? samples() else {
            return PersonalizationStoreSummary(sampleCount: recordCount(), newestSampleDate: nil)
        }

        return PersonalizationStoreSummary(
            sampleCount: samples.count,
            newestSampleDate: samples.map(\.createdAt).max()
        )
    }

    private func deduplicatedSamples(
        appending sample: PersonalizationSample,
        maxStoredSamples: Int
    ) throws -> [PersonalizationSample] {
        let dedupKey = Self.deduplicationKey(for: sample)
        let existing = try readSamples()
            .filter { Self.deduplicationKey(for: $0) != dedupKey }
        return Array(([sample] + existing)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(0, maxStoredSamples)))
    }

    private func readSamples() throws -> [PersonalizationSample] {
        try recordFiles().map { fileURL in
            let sealed = try Data(contentsOf: fileURL)
            let data = try decrypt(sealed)
            let stored = try JSONDecoder().decode(StoredPersonalizationRecord.self, from: data)
            return stored.sample
        }
    }

    private func writeSamples(_ samples: [PersonalizationSample]) throws {
        let sealedSamples = try samples.map { sample -> Data in
            let data = try JSONEncoder().encode(StoredPersonalizationRecord(sample: sample))
            return try encrypt(data)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fileURL in try recordFiles() {
            try FileManager.default.removeItem(at: fileURL)
        }

        for sealed in sealedSamples {
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString).record")
            try sealed.write(to: fileURL, options: .atomic)
        }
    }

    private func recordFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "record" }
    }

    private func encrypt(_ data: Data) throws -> Data {
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(data, using: key)

        guard let combined = sealed.combined else {
            throw SecurePersonalizationStoreError.encryptionFailed
        }

        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let key = try loadOrCreateKey()
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecurePersonalizationStoreError.decryptionFailed
        }
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try loadKeyData() {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data)
        return key
    }

    private func loadKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw SecurePersonalizationStoreError.keychain(status)
        }

        return result as? Data
    }

    private func saveKeyData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecurePersonalizationStoreError.keychain(status)
        }
    }

    private func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurePersonalizationStoreError.keychain(status)
        }
    }

    private func normalizedLanguageHint(_ languageHint: String?) -> String? {
        languageHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private func sampleRank(_ sample: PersonalizationSample, languageHint: String?) -> Int {
        guard let languageHint else {
            return sample.languageHint == nil ? 1 : 0
        }

        return sample.languageHint == languageHint ? 2 : 0
    }

    private static func deduplicationKey(for sample: PersonalizationSample) -> String {
        [
            sample.appBundleID,
            sample.domain ?? "",
            sample.languageHint ?? "",
            sample.excerpt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        ].joined(separator: "\u{1f}")
    }
}

private struct StoredPersonalizationRecord: Codable {
    let excerpt: String
    let appBundleID: String
    let domain: String?
    let languageHint: String?
    let createdAt: Date

    init(sample: PersonalizationSample) {
        self.excerpt = sample.excerpt
        self.appBundleID = sample.appBundleID
        self.domain = sample.domain
        self.languageHint = sample.languageHint
        self.createdAt = sample.createdAt
    }

    var sample: PersonalizationSample {
        PersonalizationSample(
            excerpt: excerpt,
            appBundleID: appBundleID,
            domain: domain,
            languageHint: languageHint,
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case excerpt
        case text
        case appBundleID
        case domain
        case languageHint
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
            ?? container.decode(String.self, forKey: .text)
        self.appBundleID = try container.decode(String.self, forKey: .appBundleID)
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain)
        self.languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(excerpt, forKey: .excerpt)
        try container.encode(appBundleID, forKey: .appBundleID)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(languageHint, forKey: .languageHint)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
