import AutoCompCore
import Foundation

struct HostPublishAwaitConfiguration: Equatable, Sendable {
    var firstReadDelayNanoseconds: UInt64
    var pollIntervalNanoseconds: UInt64
    var timeoutNanoseconds: UInt64

    static let `default` = HostPublishAwaitConfiguration(
        firstReadDelayNanoseconds: 10_000_000,
        pollIntervalNanoseconds: 30_000_000,
        timeoutNanoseconds: 400_000_000
    )

    var timeoutMilliseconds: Int {
        max(1, Int(timeoutNanoseconds / 1_000_000))
    }
}

enum HostPublishAwaitOutcome: Equatable, Sendable {
    case ready
    case timeout
    case cancelled
}

struct HostPublishAwaitResult: Equatable, Sendable {
    let outcome: HostPublishAwaitOutcome
    let observedContext: TextContext?
    let elapsedMs: Int
    let pollCount: Int
}

@MainActor
final class HostPublishAwaiter {
    private let configuration: HostPublishAwaitConfiguration
    private let logger = AutoCompLogger(category: "host-publish")
    private var latestGeneration = 0

    init(configuration: HostPublishAwaitConfiguration = .default) {
        self.configuration = configuration
    }

    func cancelAll(reason: String) {
        latestGeneration += 1
        logger.info("host-publish-await cancel-all generation=\(latestGeneration) reason=\(reason)")
    }

    func awaitPublication(
        after baseline: TextContext?,
        provider: TextContextProvider,
        reason: String
    ) async -> HostPublishAwaitResult {
        latestGeneration += 1
        let generation = latestGeneration
        let startedAt = ContinuousClock.now
        logger.info("host-publish-await start generation=\(generation) reason=\(reason) baseline=\(baseline != nil) firstReadMs=\(configuration.firstReadDelayNanoseconds / 1_000_000) pollMs=\(configuration.pollIntervalNanoseconds / 1_000_000) timeoutMs=\(configuration.timeoutMilliseconds)")

        if configuration.firstReadDelayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: configuration.firstReadDelayNanoseconds)
            } catch {
                return cancelledResult(generation: generation, reason: reason, startedAt: startedAt)
            }
        }

        var lastObservedContext: TextContext?
        var pollCount = 0
        while true {
            guard latestGeneration == generation, !Task.isCancelled else {
                return cancelledResult(
                    generation: generation,
                    reason: reason,
                    startedAt: startedAt,
                    pollCount: pollCount
                )
            }

            do {
                pollCount += 1
                let context = try await provider.currentContext()
                lastObservedContext = context
                if Self.hasPublishedChange(from: baseline, to: context) {
                    let elapsedMs = elapsedMs(since: startedAt)
                    logger.info("host-publish-await ready generation=\(generation) reason=\(reason) elapsedMs=\(elapsedMs)")
                    return HostPublishAwaitResult(
                        outcome: .ready,
                        observedContext: context,
                        elapsedMs: elapsedMs,
                        pollCount: pollCount
                    )
                }
            } catch {
                logger.info("host-publish-await read-failed generation=\(generation) reason=\(reason)")
            }

            let elapsedMs = elapsedMs(since: startedAt)
            if elapsedMs >= configuration.timeoutMilliseconds {
                logger.info("host-publish-await timeout generation=\(generation) reason=\(reason) elapsedMs=\(elapsedMs)")
                return HostPublishAwaitResult(
                    outcome: .timeout,
                    observedContext: lastObservedContext,
                    elapsedMs: elapsedMs,
                    pollCount: pollCount
                )
            }

            do {
                try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
            } catch {
                return cancelledResult(
                    generation: generation,
                    reason: reason,
                    startedAt: startedAt,
                    pollCount: pollCount
                )
            }
        }
    }

    private func cancelledResult(
        generation: Int,
        reason: String,
        startedAt: ContinuousClock.Instant,
        pollCount: Int = 0
    ) -> HostPublishAwaitResult {
        let elapsedMs = elapsedMs(since: startedAt)
        logger.info("host-publish-await cancelled generation=\(generation) reason=\(reason) elapsedMs=\(elapsedMs)")
        return HostPublishAwaitResult(
            outcome: .cancelled,
            observedContext: nil,
            elapsedMs: elapsedMs,
            pollCount: pollCount
        )
    }

    private func elapsedMs(since startedAt: ContinuousClock.Instant) -> Int {
        max(0, startedAt.duration(to: .now).milliseconds)
    }

    private static func hasPublishedChange(from baseline: TextContext?, to context: TextContext) -> Bool {
        guard let baseline else {
            return true
        }

        return HostPublishSnapshot(context: baseline) != HostPublishSnapshot(context: context)
    }
}

private struct HostPublishSnapshot: Equatable, Sendable {
    let app: AppIdentity
    let domain: String?
    let focusedElementID: String
    let stableFieldIdentity: StableFieldIdentity?
    let textBeforeCursor: String
    let textAfterCursor: String?
    let selectedText: String?
    let selectedRangeLocation: Int?
    let selectedRangeLength: Int?

    init(context: TextContext) {
        app = context.app
        domain = context.domain
        focusedElementID = context.focusedElementID
        stableFieldIdentity = context.stableFieldIdentity
        textBeforeCursor = context.textBeforeCursor
        textAfterCursor = context.textAfterCursor
        selectedText = context.selectedText
        selectedRangeLocation = context.selectedRange?.location
        selectedRangeLength = context.selectedRange?.length
    }
}
