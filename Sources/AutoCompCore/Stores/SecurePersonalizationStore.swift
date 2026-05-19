import CryptoKit
import Foundation
import Security

public enum SecurePersonalizationStoreError: Error, Equatable {
    case keychain(OSStatus)
    case encryptionFailed
    case decryptionFailed
}

public final class SecurePersonalizationStore: @unchecked Sendable {
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = PersonalizationRecord(text: text, appBundleID: appBundleID, domain: domain, createdAt: Date())
        let data = try JSONEncoder().encode(payload)
        let sealed = try encrypt(data)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).record")
        try sealed.write(to: fileURL, options: .atomic)
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

    private func encrypt(_ data: Data) throws -> Data {
        let key = try loadOrCreateKey()
        let sealed = try AES.GCM.seal(data, using: key)

        guard let combined = sealed.combined else {
            throw SecurePersonalizationStoreError.encryptionFailed
        }

        return combined
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
}

private struct PersonalizationRecord: Codable {
    let text: String
    let appBundleID: String
    let domain: String?
    let createdAt: Date
}
