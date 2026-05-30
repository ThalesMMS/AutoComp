import AutoCompCore
import XCTest

final class SuggestionGuardrailValidatorTests: XCTestCase {
    func testValidateAcceptBlocksAndRegeneratesWhenStale() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 1))

        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.test.app",
            processID: 123,
            domain: nil,
            role: "AXTextField",
            subrole: nil,
            roundedFocusedElementFrame: CGRect(x: 0, y: 0, width: 100, height: 20),
            focusChangeSequence: nil
        )

        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "ax:1",
            contextFingerprint: SuggestionContextFingerprint(
                prefixHash: 1,
                prefixLength: 3,
                suffixHash: 2,
                suffixLength: 0,
                selectedRange: NSRange(location: 3, length: 0),
                domain: nil
            ),
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: baselineIdentity,
            currentFocusedElementID: "ax:1",
            currentContextFingerprint: binding.contextFingerprint,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(decision, SuggestionGuardrailValidator.Decision.blockAndRegenerate(reason: .stale))
    }

    func testValidateAcceptBlocksAndHidesOnFocusedElementMismatch() {
        let validator = SuggestionGuardrailValidator(policy: .init(regenerateOnFocusedElementMismatch: false))

        let binding = SuggestionBinding(
            stableFieldIdentity: nil,
            focusedElementID: "ax:baseline",
            contextFingerprint: nil,
            caretSnapshot: nil,
            generatedAt: Date()
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: nil,
            currentFocusedElementID: "ax:current",
            currentContextFingerprint: nil,
            now: binding.generatedAt
        )

        XCTAssertEqual(decision, SuggestionGuardrailValidator.Decision.blockAndHide(reason: .focusedElementMismatch))
    }

    func testValidateAcceptAllowsFocusedElementIDDriftWhenStableFieldStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let stableIdentity = StableFieldIdentity(
            bundleID: "com.test.app",
            processID: 123,
            domain: "example.com",
            role: "AXTextArea",
            subrole: nil,
            roundedFocusedElementFrame: CGRect(x: 100, y: 100, width: 500, height: 40),
            focusChangeSequence: 4
        )
        let fingerprint = SuggestionContextFingerprint(
            prefixHash: 11,
            prefixLength: 5,
            suffixHash: 22,
            suffixLength: 0,
            selectedRange: NSRange(location: 5, length: 0),
            domain: "example.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: stableIdentity,
            focusedElementID: "volatile-field-a",
            contextFingerprint: fingerprint,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: stableIdentity,
            currentFocusedElementID: "volatile-field-b",
            currentContextFingerprint: fingerprint,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsBrailleLineMetricDriftWhenTextStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 420, y: 381, width: 626, height: 1),
            focusChangeSequence: 1
        )
        let currentIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 520, y: 381, width: 626, height: 1),
            focusChangeSequence: 2
        )
        let fingerprint = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-line-a",
            contextFingerprint: fingerprint,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: "docs-line-b",
            currentContextFingerprint: fingerprint,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsOCRLineMetricDriftWhenTextStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 430, width: 520, height: 34),
            focusChangeSequence: 1
        )
        let currentIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 476, width: 640, height: 38),
            focusChangeSequence: 2
        )
        let fingerprint = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-ocr-line-a",
            contextFingerprint: fingerprint,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: "docs-ocr-line-b",
            currentContextFingerprint: fingerprint,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsDirectToOCRIdentityDriftWhenTextStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 320, y: 210, width: 980, height: 720),
            focusChangeSequence: 1
        )
        let currentIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 476, width: 640, height: 52),
            focusChangeSequence: 2
        )
        let fingerprint = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-direct-field",
            contextFingerprint: fingerprint,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: "docs-ocr-line",
            currentContextFingerprint: fingerprint,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsRoleDriftWhenTextStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 430, width: 520, height: 34),
            focusChangeSequence: 1
        )
        let currentIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXWebArea",
            subrole: nil,
            roundedFocusedElementFrame: CGRect(x: 360, y: 476, width: 640, height: 52),
            focusChangeSequence: 2
        )
        let fingerprint = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-ax-field",
            contextFingerprint: fingerprint,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: "docs-ocr-field",
            currentContextFingerprint: fingerprint,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsMissingCurrentStableIdentityWhenTextStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 430, width: 520, height: 34),
            focusChangeSequence: 1
        )
        let fingerprint = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-ax-field",
            contextFingerprint: fingerprint,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: nil,
            currentFocusedElementID: "docs-ocr-field",
            currentContextFingerprint: fingerprint,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsCollapsedSelectionRangeDriftWhenTextStillMatches() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 430, width: 520, height: 34),
            focusChangeSequence: 1
        )
        let currentIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 476, width: 640, height: 52),
            focusChangeSequence: 2
        )
        let baseline = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let current = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: nil,
            domain: "docs.google.com"
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-ax-field",
            contextFingerprint: baseline,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: "docs-ocr-field",
            currentContextFingerprint: current,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptAllowsGoogleDocsMissingFingerprintDomainWhenTextAndChromeTargetStillMatch() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))
        let baselineIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 430, width: 520, height: 34),
            focusChangeSequence: 1
        )
        let currentIdentity = StableFieldIdentity(
            bundleID: "com.google.Chrome",
            processID: 456,
            domain: "docs.google.com",
            role: "AXTextArea",
            subrole: "AXDocument",
            roundedFocusedElementFrame: CGRect(x: 360, y: 476, width: 640, height: 52),
            focusChangeSequence: 2
        )
        let baseline = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: "docs.google.com"
        )
        let current = SuggestionContextFingerprint(
            prefixHash: 31,
            prefixLength: 9,
            suffixHash: 0,
            suffixLength: 0,
            selectedRange: NSRange(location: 9, length: 0),
            domain: nil
        )
        let binding = SuggestionBinding(
            stableFieldIdentity: baselineIdentity,
            focusedElementID: "docs-ax-field",
            contextFingerprint: baseline,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: "docs-ocr-field",
            currentContextFingerprint: current,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, .allowAccept)
    }

    func testValidateAcceptBlocksAndHidesOnStableFieldIdentityMismatch() {
        let validator = SuggestionGuardrailValidator()

        let bindingIdentity = StableFieldIdentity(
            bundleID: "com.test.app",
            processID: 1,
            domain: nil,
            role: "AXTextField",
            subrole: nil,
            roundedFocusedElementFrame: CGRect(x: 0, y: 0, width: 100, height: 20),
            focusChangeSequence: nil
        )

        let currentIdentity = StableFieldIdentity(
            bundleID: "com.test.app",
            processID: 1,
            domain: nil,
            role: "AXTextField",
            subrole: nil,
            roundedFocusedElementFrame: CGRect(x: 0, y: 50, width: 100, height: 20),
            focusChangeSequence: nil
        )

        let binding = SuggestionBinding(
            stableFieldIdentity: bindingIdentity,
            focusedElementID: nil,
            contextFingerprint: nil,
            caretSnapshot: nil,
            generatedAt: Date()
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: currentIdentity,
            currentFocusedElementID: nil,
            currentContextFingerprint: nil,
            now: binding.generatedAt
        )

        XCTAssertEqual(decision, SuggestionGuardrailValidator.Decision.blockAndHide(reason: .fieldIdentityMismatch))
    }

    func testValidateAcceptBlocksAndRegeneratesOnContextDrift() {
        let validator = SuggestionGuardrailValidator(policy: .init(regenerateOnContextDrift: true))

        let baseline = SuggestionContextFingerprint(
            prefixHash: 11,
            prefixLength: 3,
            suffixHash: 22,
            suffixLength: 0,
            selectedRange: NSRange(location: 3, length: 0),
            domain: "example.com"
        )

        let current = SuggestionContextFingerprint(
            prefixHash: 999,
            prefixLength: 3,
            suffixHash: 22,
            suffixLength: 0,
            selectedRange: NSRange(location: 3, length: 0),
            domain: "example.com"
        )

        let binding = SuggestionBinding(
            stableFieldIdentity: nil,
            focusedElementID: nil,
            contextFingerprint: baseline,
            caretSnapshot: nil,
            generatedAt: Date()
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: nil,
            currentFocusedElementID: nil,
            currentContextFingerprint: current,
            now: binding.generatedAt
        )

        XCTAssertEqual(decision, SuggestionGuardrailValidator.Decision.blockAndRegenerate(reason: .contextDrift))
    }

    func testValidateAcceptAllowsWhenAllChecksPass() {
        let validator = SuggestionGuardrailValidator(policy: .init(freshnessWindow: 10))

        let baseline = SuggestionContextFingerprint(
            prefixHash: 11,
            prefixLength: 3,
            suffixHash: 22,
            suffixLength: 0,
            selectedRange: NSRange(location: 3, length: 0),
            domain: nil
        )

        let binding = SuggestionBinding(
            stableFieldIdentity: nil,
            focusedElementID: "ax:ok",
            contextFingerprint: baseline,
            caretSnapshot: nil,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let decision = validator.validateAccept(
            binding: binding,
            currentStableFieldIdentity: nil,
            currentFocusedElementID: "ax:ok",
            currentContextFingerprint: baseline,
            now: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(decision, SuggestionGuardrailValidator.Decision.allowAccept)
    }
}
