@testable import AutoCompApp
import XCTest

final class SecureFieldClassifierTests: XCTestCase {
    func testExplicitSecureAXRolesAreBlocked() {
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(role: "AXSecureTextField")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(subrole: "AXSecureTextField")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(roleDescription: "secure text field")))
    }

    func testPasswordMetadataAcrossNamesIdentifiersAndPlaceholdersIsBlocked() {
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(title: "Password")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(description: "Current passcode")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(help: "Enter your recovery phrase")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(identifier: "login-password-input")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(placeholder: "Master password")))
    }

    func testBrowserAndWebViewPasswordSignalsAreBlockedWhenDetectable() {
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(domType: "password")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(domIdentifier: "signin-passwd")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(domClassList: ["form-control", "password-field"])))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(identifier: "electron-auth-secret")))
    }

    func testMaskedValuesAreBlockedWithoutReadingAsNormalText() {
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(value: "******")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(value: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(value: "\u{25CF}\u{25CF}\u{25CF}\u{25CF}")))
    }

    func testCommonSensitiveVerificationFieldsAreBlocked() {
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(placeholder: "Verification code")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(identifier: "totp-code")))
        XCTAssertTrue(SecureFieldClassifier.isSecure(SecureFieldMetadata(title: "CVV")))
    }

    func testOrdinaryTextAndLoginMetadataAloneAreNotBlocked() {
        XCTAssertFalse(SecureFieldClassifier.isSecure(SecureFieldMetadata(title: "Login")))
        XCTAssertFalse(SecureFieldClassifier.isSecure(SecureFieldMetadata(identifier: "shipping-pinboard")))
        XCTAssertFalse(SecureFieldClassifier.isSecure(SecureFieldMetadata(value: "my password manager notes")))
        XCTAssertFalse(SecureFieldClassifier.isSecure(SecureFieldMetadata(value: "**")))
        XCTAssertFalse(SecureFieldClassifier.isSecure(SecureFieldMetadata(domClassList: ["input", "email"])))
    }
}
