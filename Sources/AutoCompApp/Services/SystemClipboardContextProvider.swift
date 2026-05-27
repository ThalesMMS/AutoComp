import AppKit
import AutoCompCore
import Foundation

protocol ClipboardReading: Sendable {
    var changeCount: Int { get }
    func stringValue() -> String?
}

final class SystemClipboardReader: ClipboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func stringValue() -> String? {
        pasteboard.string(forType: .string)
    }
}

final class SystemClipboardContextProvider: ClipboardContextProvider, @unchecked Sendable {
    private let reader: any ClipboardReading
    private let relevanceFilter: ClipboardRelevanceFilter
    private let distiller: ClipboardContentDistiller
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let baselineChangeCount: Int
    private let lock = NSLock()

    private var observedChangeCount: Int?
    private var observedAt: Date?

    init(
        reader: any ClipboardReading = SystemClipboardReader(),
        relevanceFilter: ClipboardRelevanceFilter = ClipboardRelevanceFilter(),
        distiller: ClipboardContentDistiller = ClipboardContentDistiller(),
        ttl: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.relevanceFilter = relevanceFilter
        self.distiller = distiller
        self.ttl = max(1, ttl)
        self.now = now
        self.baselineChangeCount = reader.changeCount
    }

    func currentClipboardContext(
        for context: TextContext,
        privacySettings: PrivacySettings
    ) -> ClipboardContextSnapshot? {
        guard privacySettings.clipboardContextEnabled else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        let currentChangeCount = reader.changeCount
        let currentTime = now()

        guard currentChangeCount > baselineChangeCount else {
            return omitted(.omittedBeforeBaseline, createdAt: currentTime)
        }

        if observedChangeCount != currentChangeCount {
            observedChangeCount = currentChangeCount
            observedAt = currentTime
        }

        if let observedAt,
           currentTime.timeIntervalSince(observedAt) > ttl {
            return omitted(.omittedExpired, createdAt: currentTime)
        }

        guard let rawText = reader.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return omitted(.omittedEmpty, createdAt: currentTime)
        }

        let relevance = relevanceFilter.evaluate(
            clipboardText: rawText,
            textBeforeCursor: context.textBeforeCursor
        )
        guard relevance.isRelevant else {
            return omitted(.omittedNotRelevant, createdAt: currentTime)
        }

        let distilled = distiller.distill(rawText, matchingTokens: relevance.overlappingTokens)
        guard !distilled.isEmpty else {
            return omitted(.omittedEmpty, createdAt: currentTime)
        }

        return ClipboardContextSnapshot(
            summary: distilled,
            status: .included,
            captureSources: [.clipboard],
            createdAt: currentTime
        )
    }

    private func omitted(
        _ status: ClipboardContextSnapshot.Status,
        createdAt: Date
    ) -> ClipboardContextSnapshot {
        ClipboardContextSnapshot(
            summary: "",
            status: status,
            createdAt: createdAt
        )
    }
}
