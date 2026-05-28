import Foundation

public struct CompletionStopSequences: Codable, Equatable, Sendable {
    public var continuation: [String]
    public var fillInMiddle: [String]

    public init(
        continuation: [String] = CompletionStopSequences.conservativeDefault.continuation,
        fillInMiddle: [String] = CompletionStopSequences.conservativeDefault.fillInMiddle
    ) {
        self.continuation = Self.normalized(continuation)
        self.fillInMiddle = Self.normalized(fillInMiddle)
    }

    public static let conservativeDefault = CompletionStopSequences(
        uncheckedContinuation: [
            "<|fim_prefix|>",
            "<|fim_suffix|>",
            "<|fim_middle|>",
            "<|endoftext|>",
            "</s>"
        ],
        uncheckedFillInMiddle: [
            "<|fim_prefix|>",
            "<|fim_suffix|>",
            "<|fim_middle|>",
            "<|endoftext|>",
            "</s>"
        ]
    )

    public static let disabled = CompletionStopSequences(
        uncheckedContinuation: [],
        uncheckedFillInMiddle: []
    )

    public func sequences(for mode: CompletionRequestMode) -> [String] {
        switch mode {
        case .continuation:
            return continuation
        case .fillInMiddle:
            return fillInMiddle
        }
    }

    private init(uncheckedContinuation: [String], uncheckedFillInMiddle: [String]) {
        self.continuation = uncheckedContinuation
        self.fillInMiddle = uncheckedFillInMiddle
    }

    private static func normalized(_ sequences: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for sequence in sequences {
            guard !sequence.isEmpty, !seen.contains(sequence) else {
                continue
            }
            seen.insert(sequence)
            result.append(sequence)
        }
        return result
    }
}

public enum CompletionStopSequenceTrimmer {
    public static func trim(_ text: String, stopSequences: [String]) -> String {
        let normalizedStops = CompletionStopSequences(
            continuation: stopSequences,
            fillInMiddle: []
        ).continuation
        guard !normalizedStops.isEmpty else {
            return text
        }

        var earliestStop: String.Index?
        for stopSequence in normalizedStops {
            guard let range = text.range(of: stopSequence) else {
                continue
            }
            if earliestStop == nil || range.lowerBound < earliestStop! {
                earliestStop = range.lowerBound
            }
        }

        guard let earliestStop else {
            return text
        }
        return String(text[..<earliestStop]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
