import Foundation

public enum PersonalizationSampleRecordingSkipReason: String, Equatable, Sendable {
    case localPersonalizationDisabled = "local-personalization-disabled"
    case secureField = "secure-field"
    case collectionNotAllowed = "collection-not-allowed"
    case excerptTooShort = "excerpt-too-short"
    case sensitivePattern = "sensitive-pattern"
    case storeUnavailable = "store-unavailable"
}

public enum PersonalizationSampleRecordingDecision: Equatable, Sendable {
    case recorded(PersonalizationSample)
    case skipped(PersonalizationSampleRecordingSkipReason)
}

public final class PersonalizationSampleRecorder: @unchecked Sendable {
    public static let defaultPromptSampleLimit = 3
    public static let defaultMinimumExcerptCharacters = 12

    private let store: SecurePersonalizationStore
    private let now: () -> Date
    private let maxStoredSamples: Int
    private let maxExcerptCharacters: Int
    private let minimumExcerptCharacters: Int

    public init(
        store: SecurePersonalizationStore,
        now: @escaping () -> Date = Date.init,
        maxStoredSamples: Int = SecurePersonalizationStore.defaultMaxStoredSamples,
        maxExcerptCharacters: Int = SecurePersonalizationStore.defaultMaxExcerptCharacters,
        minimumExcerptCharacters: Int = PersonalizationSampleRecorder.defaultMinimumExcerptCharacters
    ) {
        self.store = store
        self.now = now
        self.maxStoredSamples = maxStoredSamples
        self.maxExcerptCharacters = maxExcerptCharacters
        self.minimumExcerptCharacters = minimumExcerptCharacters
    }

    @discardableResult
    public func recordSample(
        from context: TextContext,
        privacySettings: PrivacySettings,
        isSecureField: Bool = false
    ) -> PersonalizationSampleRecordingDecision {
        recordSample(
            text: context.textBeforeCursor,
            appBundleID: context.app.bundleID,
            domain: context.domain,
            languageHint: context.languageHint,
            privacySettings: privacySettings,
            isSecureField: isSecureField
        )
    }

    @discardableResult
    public func recordSample(
        text: String,
        appBundleID: String,
        domain: String?,
        languageHint: String?,
        privacySettings: PrivacySettings,
        isSecureField: Bool = false
    ) -> PersonalizationSampleRecordingDecision {
        guard privacySettings.localPersonalizationEnabled else {
            return .skipped(.localPersonalizationDisabled)
        }

        guard !isSecureField else {
            return .skipped(.secureField)
        }

        guard privacySettings.collectionDecision(appBundleID: appBundleID, domain: domain).allowed else {
            return .skipped(.collectionNotAllowed)
        }

        guard !Self.containsSensitivePattern(text) else {
            return .skipped(.sensitivePattern)
        }

        guard let excerpt = Self.filteredExcerpt(
            from: text,
            maxCharacters: maxExcerptCharacters,
            minimumCharacters: minimumExcerptCharacters
        ) else {
            return .skipped(.excerptTooShort)
        }

        guard !Self.containsSensitivePattern(excerpt) else {
            return .skipped(.sensitivePattern)
        }

        do {
            let sample = try store.appendSample(
                excerpt: excerpt,
                appBundleID: appBundleID,
                domain: domain,
                languageHint: languageHint,
                createdAt: now(),
                maxStoredSamples: maxStoredSamples,
                maxExcerptCharacters: maxExcerptCharacters
            )
            return .recorded(sample)
        } catch {
            return .skipped(.storeUnavailable)
        }
    }

    public func promptSamples(
        for context: TextContext,
        privacySettings: PrivacySettings,
        limit: Int? = nil
    ) -> [PersonalizationSample] {
        guard privacySettings.localPersonalizationEnabled,
              privacySettings.collectionDecision(
                appBundleID: context.app.bundleID,
                domain: context.domain
              ).allowed else {
            return []
        }

        let resolvedLimit = limit ?? privacySettings.personalizationPromptSampleLimit
        guard resolvedLimit > 0 else {
            return []
        }

        return (try? store.promptSamples(
            appBundleID: context.app.bundleID,
            domain: context.domain,
            languageHint: context.languageHint,
            limit: resolvedLimit
        )) ?? []
    }

    public static func filteredExcerpt(
        from text: String,
        maxCharacters: Int,
        minimumCharacters: Int
    ) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(collapsed.suffix(max(0, maxCharacters)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard excerpt.count >= max(0, minimumCharacters) else {
            return nil
        }
        return excerpt
    }

    public static func containsSensitivePattern(_ text: String) -> Bool {
        sensitivePatterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    // Heuristic local PII guardrails. These reduce obvious sensitive samples but
    // are not a complete data-loss-prevention classifier.
    private static let sensitivePatterns = [
        #"(?i)\b(pass(word|code|phrase)?|secret|token|api[_\s-]?key)\b\s*[:=]"#,
        #"\b(?:\d[ -]?){13,19}\b"#,
        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        #"\b\d{3}-\d{2}-\d{4}\b"#,
        #"(?i)\b(date\s*of\s*birth|dob|birth\s*date)\b\s*[:=]?\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}[/-]\d{1,2}[/-]\d{1,2})\b"#,
        #"(?i)\b(phone|tel|mobile|cell)\b\s*[:=]?\s*(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b"#,
        #"\b(\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b"#
    ]
}
