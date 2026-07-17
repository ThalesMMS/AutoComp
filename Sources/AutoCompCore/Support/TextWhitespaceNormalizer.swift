import Foundation

enum TextWhitespaceNormalizer {
    private static let whitespaceExpression = try! NSRegularExpression(pattern: #"\s+"#)

    static func collapse(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return whitespaceExpression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: " "
        )
    }

    static func normalize(_ text: String, maxCharacters: Int) -> String {
        let collapsed = collapse(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(0, maxCharacters)
        guard collapsed.count > limit else {
            return collapsed
        }
        return String(collapsed.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
