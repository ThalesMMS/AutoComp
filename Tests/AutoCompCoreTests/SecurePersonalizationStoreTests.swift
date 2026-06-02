import AutoCompCore
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
}
