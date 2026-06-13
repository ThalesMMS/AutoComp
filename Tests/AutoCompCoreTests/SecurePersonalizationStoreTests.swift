import AutoCompCore
import Dispatch
import XCTest

final class SecurePersonalizationStoreTests: XCTestCase {
    func testDeleteAllRemovesEncryptedRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompTests-\(UUID().uuidString)", isDirectory: true)
        let store = SecurePersonalizationStore(
            directory: directory,
            service: "com.autocomp.tests.\(UUID().uuidString)"
        )

        try store.append("hello", appBundleID: "com.apple.TextEdit", domain: nil)
        XCTAssertEqual(store.recordCount(), 1)

        try store.deleteAll()
        XCTAssertEqual(store.recordCount(), 0)
    }

    func testAppendSampleDeduplicatesCapsAndScopesPromptSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompTests-\(UUID().uuidString)", isDirectory: true)
        let store = SecurePersonalizationStore(
            directory: directory,
            service: "com.autocomp.tests.\(UUID().uuidString)"
        )
        defer {
            try? store.deleteAll()
        }

        try store.appendSample(
            excerpt: "first same-domain sample",
            appBundleID: "com.example.Writer",
            domain: "https://docs.example.com/path?query=1",
            languageHint: "EN-US",
            createdAt: Date(timeIntervalSince1970: 10),
            maxStoredSamples: 4,
            maxExcerptCharacters: 80
        )
        try store.appendSample(
            excerpt: "first same-domain sample",
            appBundleID: "com.example.Writer",
            domain: "docs.example.com/path",
            languageHint: "en-us",
            createdAt: Date(timeIntervalSince1970: 20),
            maxStoredSamples: 4,
            maxExcerptCharacters: 80
        )
        try store.appendSample(
            excerpt: "second same-domain sample",
            appBundleID: "com.example.Writer",
            domain: "docs.example.com/path",
            languageHint: "pt-BR",
            createdAt: Date(timeIntervalSince1970: 30),
            maxStoredSamples: 4,
            maxExcerptCharacters: 80
        )
        try store.appendSample(
            excerpt: "other-domain sample",
            appBundleID: "com.example.Writer",
            domain: "mail.example.com",
            languageHint: "en-us",
            createdAt: Date(timeIntervalSince1970: 40),
            maxStoredSamples: 4,
            maxExcerptCharacters: 80
        )
        try store.appendSample(
            excerpt: "other-app sample",
            appBundleID: "com.example.Other",
            domain: nil,
            languageHint: "en-us",
            createdAt: Date(timeIntervalSince1970: 50),
            maxStoredSamples: 4,
            maxExcerptCharacters: 80
        )

        XCTAssertEqual(store.recordCount(), 4)

        let scoped = try store.promptSamples(
            appBundleID: "com.example.Writer",
            domain: "https://docs.example.com/path",
            languageHint: "en-us",
            limit: 2
        )
        XCTAssertEqual(scoped.map(\.excerpt), [
            "first same-domain sample",
            "second same-domain sample"
        ])
        XCTAssertTrue(scoped.allSatisfy { $0.domain == "docs.example.com/path" })
    }

    func testConcurrentAppendsPreserveAllSamples() throws {
        let directory = temporaryStoreDirectory()
        let store = SecurePersonalizationStore(
            directory: directory,
            service: "com.autocomp.tests.\(UUID().uuidString)"
        )
        defer {
            try? store.deleteAll()
        }

        try store.appendSample(
            excerpt: "warmup sample",
            appBundleID: "com.example.Writer",
            domain: nil,
            languageHint: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            maxStoredSamples: 100,
            maxExcerptCharacters: 80
        )
        try removeRecordFiles(in: directory)

        let sampleCount = 64
        let errors = ConcurrentErrorRecorder()
        DispatchQueue.concurrentPerform(iterations: sampleCount) { index in
            do {
                try store.appendSample(
                    excerpt: "concurrent sample \(index)",
                    appBundleID: "com.example.Writer",
                    domain: nil,
                    languageHint: nil,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                    maxStoredSamples: 100,
                    maxExcerptCharacters: 80
                )
            } catch {
                errors.record(error)
            }
        }

        XCTAssertTrue(errors.allErrors.isEmpty, "Concurrent appends should not throw: \(errors.allErrors)")
        let samples = try store.samples(limit: sampleCount)
        XCTAssertEqual(Set(samples.map(\.excerpt)).count, sampleCount)
        XCTAssertEqual(
            Set(samples.map(\.excerpt)),
            Set((0..<sampleCount).map { "concurrent sample \($0)" })
        )
    }

    func testConcurrentFirstUseWithSharedKeychainServiceKeepsStoresReadable() throws {
        let service = "com.autocomp.tests.\(UUID().uuidString)"
        let stores = (0..<2).map { index in
            SecurePersonalizationStore(
                directory: temporaryStoreDirectory(named: "AutoCompTests-\(UUID().uuidString)-\(index)"),
                service: service
            )
        }
        defer {
            for store in stores {
                try? store.deleteAll()
            }
        }

        let errors = ConcurrentErrorRecorder()
        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            do {
                try stores[index].appendSample(
                    excerpt: "first use sample \(index)",
                    appBundleID: "com.example.Writer",
                    domain: nil,
                    languageHint: nil,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    maxStoredSamples: 10,
                    maxExcerptCharacters: 80
                )
            } catch {
                errors.record(error)
            }
        }

        XCTAssertTrue(errors.allErrors.isEmpty, "Concurrent key creation should not throw: \(errors.allErrors)")
        for (index, store) in stores.enumerated() {
            XCTAssertEqual(try store.samples().map(\.excerpt), ["first use sample \(index)"])
        }
    }

    func testRecorderRequiresOptInAllowedSourceAndSafeExcerpt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompTests-\(UUID().uuidString)", isDirectory: true)
        let store = SecurePersonalizationStore(
            directory: directory,
            service: "com.autocomp.tests.\(UUID().uuidString)"
        )
        let recorder = PersonalizationSampleRecorder(
            store: store,
            now: { Date(timeIntervalSince1970: 100) },
            maxStoredSamples: 10,
            maxExcerptCharacters: 24,
            minimumExcerptCharacters: 8
        )
        defer {
            try? store.deleteAll()
        }

        let context = textContext(
            textBeforeCursor: "This is a longer paragraph that should become a short local sample.",
            domain: "example.com",
            languageHint: "en-US"
        )

        XCTAssertEqual(
            recorder.recordSample(from: context, privacySettings: PrivacySettings()),
            .skipped(.localPersonalizationDisabled)
        )

        let enabled = PrivacySettings(
            collectionEnabled: true,
            localPersonalizationEnabled: true
        )
        XCTAssertEqual(
            recorder.recordSample(from: context, privacySettings: enabled, isSecureField: true),
            .skipped(.secureField)
        )

        var appDisabled = enabled
        appDisabled.perAppRules["com.example.Writer"] = false
        XCTAssertEqual(
            recorder.recordSample(from: context, privacySettings: appDisabled),
            .skipped(.collectionNotAllowed)
        )

        XCTAssertEqual(
            recorder.recordSample(
                text: "api key: secret-material",
                appBundleID: "com.example.Writer",
                domain: nil,
                languageHint: nil,
                privacySettings: enabled
            ),
            .skipped(.sensitivePattern)
        )

        for sensitiveText in [
            "Contact jane.doe@example.com for the draft.",
            "SSN: 123-45-6789",
            "DOB: 01/02/1990",
            "Call 555-123-4567 after lunch."
        ] {
            XCTAssertEqual(
                recorder.recordSample(
                    text: sensitiveText,
                    appBundleID: "com.example.Writer",
                    domain: nil,
                    languageHint: nil,
                    privacySettings: enabled
                ),
                .skipped(.sensitivePattern),
                sensitiveText
            )
        }

        guard case .recorded(let sample) = recorder.recordSample(from: context, privacySettings: enabled) else {
            return XCTFail("Expected sample to be recorded")
        }
        XCTAssertLessThanOrEqual(sample.excerpt.count, 24)
        XCTAssertEqual(sample.domain, "example.com")
        XCTAssertEqual(sample.languageHint, "en-us")
        XCTAssertEqual(store.recordCount(), 1)
    }

    func testRecorderUsesPersonalizationStrengthForPromptSampleLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompTests-\(UUID().uuidString)", isDirectory: true)
        let store = SecurePersonalizationStore(
            directory: directory,
            service: "com.autocomp.tests.\(UUID().uuidString)"
        )
        let recorder = PersonalizationSampleRecorder(store: store)
        defer {
            try? store.deleteAll()
        }

        for index in 1...3 {
            try store.appendSample(
                excerpt: "local style sample \(index)",
                appBundleID: "com.example.Writer",
                domain: "example.com",
                languageHint: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                maxStoredSamples: 10,
                maxExcerptCharacters: 80
            )
        }

        let context = textContext(textBeforeCursor: "Please continue", domain: "example.com")
        let disabledContribution = PrivacySettings(
            collectionEnabled: true,
            localPersonalizationEnabled: true,
            personalizationStrength: 0
        )
        let mediumContribution = PrivacySettings(
            collectionEnabled: true,
            localPersonalizationEnabled: true,
            personalizationStrength: 0.35
        )
        let fullContribution = PrivacySettings(
            collectionEnabled: true,
            localPersonalizationEnabled: true,
            personalizationStrength: 1
        )

        XCTAssertEqual(recorder.promptSamples(for: context, privacySettings: disabledContribution).count, 0)
        XCTAssertEqual(recorder.promptSamples(for: context, privacySettings: mediumContribution).count, 2)
        XCTAssertEqual(recorder.promptSamples(for: context, privacySettings: fullContribution).count, 3)
    }

    private func textContext(
        textBeforeCursor: String,
        domain: String? = nil,
        languageHint: String? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.example.Writer", displayName: "Writer", processID: 42),
            domain: domain,
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            languageHint: languageHint
        )
    }

    private func temporaryStoreDirectory(named name: String = "AutoCompTests-\(UUID().uuidString)") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
    }

    private func removeRecordFiles(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for fileURL in files where fileURL.pathExtension == "record" {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

private final class ConcurrentErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrors: [Error] = []

    var allErrors: [Error] {
        lock.withLock { storedErrors }
    }

    func record(_ error: Error) {
        lock.withLock {
            storedErrors.append(error)
        }
    }
}
