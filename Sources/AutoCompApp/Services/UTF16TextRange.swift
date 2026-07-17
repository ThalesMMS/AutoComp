import Foundation

enum UTF16TextRange {
    static func prefix(_ text: String, endingAt rawOffset: Int) -> String {
        let nsText = text as NSString
        let end = boundaryAtOrBefore(rawOffset, in: nsText)
        return nsText.substring(to: end)
    }

    static func suffix(_ text: String, startingAt rawOffset: Int) -> String {
        let nsText = text as NSString
        let start = boundaryAtOrAfter(rawOffset, in: nsText)
        return nsText.substring(from: start)
    }

    static func substring(_ text: String, enclosedBy rawRange: NSRange) -> String? {
        let nsText = text as NSString
        guard rawRange.location >= 0,
              rawRange.length >= 0,
              rawRange.location <= nsText.length,
              NSMaxRange(rawRange) <= nsText.length else {
            return nil
        }
        let start = boundaryAtOrAfter(rawRange.location, in: nsText)
        let end = boundaryAtOrBefore(NSMaxRange(rawRange), in: nsText)
        guard end >= start else { return "" }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }

    private static func boundaryAtOrBefore(_ rawOffset: Int, in text: NSString) -> Int {
        let offset = min(max(0, rawOffset), text.length)
        guard offset > 0, offset < text.length else { return offset }
        let sequence = text.rangeOfComposedCharacterSequence(at: offset)
        return sequence.location < offset ? sequence.location : offset
    }

    private static func boundaryAtOrAfter(_ rawOffset: Int, in text: NSString) -> Int {
        let offset = min(max(0, rawOffset), text.length)
        guard offset > 0, offset < text.length else { return offset }
        let sequence = text.rangeOfComposedCharacterSequence(at: offset)
        return sequence.location < offset ? NSMaxRange(sequence) : offset
    }
}
