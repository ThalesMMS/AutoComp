import Foundation

struct SecureFieldMetadata: Equatable {
    var role: String?
    var subrole: String?
    var roleDescription: String?
    var title: String?
    var description: String?
    var help: String?
    var identifier: String?
    var placeholder: String?
    var domType: String?
    var domIdentifier: String?
    var domClassList: [String] = []
    var value: String?

    var searchableMetadata: [String] {
        [
            role,
            subrole,
            roleDescription,
            title,
            description,
            help,
            identifier,
            placeholder,
            domType,
            domIdentifier
        ].compactMap { $0 } + domClassList
    }
}

enum SecureFieldClassifier {
    static func isSecure(_ metadata: SecureFieldMetadata) -> Bool {
        if metadata.searchableMetadata.contains(where: containsSecureSignal) {
            return true
        }

        guard let value = metadata.value else {
            return false
        }
        return isMaskedValue(value)
    }

    private static func containsSecureSignal(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard !normalized.isEmpty else {
            return false
        }

        let compact = normalized.replacingOccurrences(of: " ", with: "")
        if compact.contains("securetextfield")
            || compact.contains("password")
            || compact.contains("passcode")
            || compact.contains("passphrase")
            || compact.contains("passwd")
            || compact.contains("recoveryphrase")
            || compact.contains("privatekey") {
            return true
        }

        if normalized.contains("one time code")
            || normalized.contains("verification code")
            || normalized.contains("security code") {
            return true
        }

        let tokens = Set(normalized.split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: [
            "secure",
            "pwd",
            "pin",
            "otp",
            "totp",
            "cvv",
            "cvc",
            "secret"
        ])
    }

    private static func isMaskedValue(_ value: String) -> Bool {
        let maskScalars: Set<UnicodeScalar> = [
            "*",
            "\u{2022}", // bullet
            "\u{2023}", // triangular bullet
            "\u{2024}", // one dot leader
            "\u{2027}", // hyphenation point
            "\u{2219}", // bullet operator
            "\u{25CF}", // black circle
            "\u{25E6}"  // white bullet
        ]
        let visibleScalars = value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard visibleScalars.count >= 3 else {
            return false
        }
        return visibleScalars.allSatisfy { maskScalars.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var result = ""
        var lastWasSeparator = true

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append(" ")
                lastWasSeparator = true
            }
        }

        if result.last == " " {
            result.removeLast()
        }
        return result
    }
}
