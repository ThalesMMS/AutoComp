import Foundation

public enum SpeculativePostAcceptanceIneligibility: String, Equatable, Sendable {
    case disabled
    case unsupportedBackend = "unsupported-backend"
    case emptyInsertion = "empty-insertion"
    case activeSelection = "active-selection"
    case composingText = "composing-text"
}

public struct SpeculativeContextSignature: Equatable, Sendable {
    public let target: ActiveSuggestionTarget
    public let expectedTextBeforeCursor: String

    public init(context: TextContext) {
        target = ActiveSuggestionTarget(context: context)
        expectedTextBeforeCursor = context.textBeforeCursor
    }

    public func matches(_ context: TextContext) -> Bool {
        guard context.app == target.app,
              context.domain == target.domain,
              context.textBeforeCursor == expectedTextBeforeCursor,
              (context.textAfterCursor ?? "") == (target.textAfterCursor ?? ""),
              context.selectedText == target.selectedText,
              context.selectedRange == target.selectedRange else {
            return false
        }
        if let expected = target.stableFieldIdentity,
           let current = context.stableFieldIdentity {
            return expected.matchesStableTarget(current)
        }
        return context.focusedElementID == target.focusedElementID
    }
}

public struct SpeculativePostAcceptanceContext: Equatable, Sendable {
    public let context: TextContext
    public let signature: SpeculativeContextSignature
    public let route: CompletionEngineKind

    public init(context: TextContext, route: CompletionEngineKind) {
        self.context = context
        self.signature = SpeculativeContextSignature(context: context)
        self.route = route
    }
}

public enum PostAcceptanceSpeculationDecision: Equatable, Sendable {
    case start(SpeculativePostAcceptanceContext)
    case ineligible(SpeculativePostAcceptanceIneligibility)
}

public struct PostAcceptanceSpeculationPolicy: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var enabled: Bool
        public var allowedBackends: Set<CompletionEngineKind>
        public var commandWindow: TimeInterval

        public init(
            enabled: Bool = false,
            allowedBackends: Set<CompletionEngineKind> = [.localLlama],
            commandWindow: TimeInterval = 0.45
        ) {
            self.enabled = enabled
            self.allowedBackends = allowedBackends
            self.commandWindow = max(0.05, commandWindow)
        }

        public static func environmentDefault(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            let value = environment["AUTOCOMP_ENABLE_POST_ACCEPTANCE_PREFETCH"]?.lowercased()
            return Configuration(enabled: ["1", "true", "yes", "on"].contains(value ?? ""))
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .environmentDefault()) {
        self.configuration = configuration
    }

    public func decision(
        context: TextContext,
        insertedText: String,
        route: CompletionEngineKind,
        inputMethodState: InputMethodState
    ) -> PostAcceptanceSpeculationDecision {
        guard configuration.enabled else { return .ineligible(.disabled) }
        guard configuration.allowedBackends.contains(route) else { return .ineligible(.unsupportedBackend) }
        guard !insertedText.isEmpty else { return .ineligible(.emptyInsertion) }
        guard !inputMethodState.isComposingText else { return .ineligible(.composingText) }
        guard (context.selectedRange?.length ?? 0) == 0,
              context.selectedText?.isEmpty != false else {
            return .ineligible(.activeSelection)
        }

        let insertedUTF16Length = (insertedText as NSString).length
        let expectedSelection = context.selectedRange.map {
            NSRange(location: $0.location + insertedUTF16Length, length: 0)
        }
        let expectedContext = TextContext(
            id: context.id,
            app: context.app,
            domain: context.domain,
            focusedElementID: context.focusedElementID,
            stableFieldIdentity: context.stableFieldIdentity,
            textBeforeCursor: context.textBeforeCursor + insertedText,
            textAfterCursor: context.textAfterCursor,
            selectedText: context.selectedText,
            fullTextWindow: context.fullTextWindow,
            selectedRange: expectedSelection,
            caretRect: context.caretRect,
            focusedElementRect: context.focusedElementRect,
            previousGlyphRect: context.previousGlyphRect,
            nextGlyphRect: context.nextGlyphRect,
            lineReferenceRect: context.lineReferenceRect,
            caretGeometryQuality: context.caretGeometryQuality,
            caretGeometryProvenance: context.caretGeometryProvenance,
            caretGeometryCoordinateSpace: context.caretGeometryCoordinateSpace,
            observedCharacterWidth: context.observedCharacterWidth,
            languageHint: context.languageHint,
            captureSources: context.captureSources,
            createdAt: context.createdAt
        )
        return .start(SpeculativePostAcceptanceContext(context: expectedContext, route: route))
    }
}

public enum PostAcceptanceCommandEnqueueDecision: Equatable, Sendable {
    case queued(generation: UInt64)
    case alreadyQueued(generation: UInt64)
    case inactive
}

public struct PostAcceptanceCommandBuffer: Equatable, Sendable {
    public enum CloseReason: String, Equatable, Sendable {
        case consumed
        case expired
        case incompatibleInput = "incompatible-input"
        case focusChanged = "focus-changed"
        case insertionFailed = "insertion-failed"
        case teardown
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var expiresAt: Date?
    public private(set) var hasQueuedCommand = false
    public private(set) var lastCloseReason: CloseReason?

    public init() {}

    @discardableResult
    public mutating func arm(duration: TimeInterval, now: Date = Date()) -> UInt64 {
        generation &+= 1
        expiresAt = now.addingTimeInterval(max(0.05, duration))
        hasQueuedCommand = false
        lastCloseReason = nil
        return generation
    }

    public func shouldIntercept(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now < expiresAt
    }

    public mutating func enqueue(now: Date = Date()) -> PostAcceptanceCommandEnqueueDecision {
        guard shouldIntercept(now: now) else { return .inactive }
        if hasQueuedCommand { return .alreadyQueued(generation: generation) }
        hasQueuedCommand = true
        return .queued(generation: generation)
    }

    @discardableResult
    public mutating func consume(now: Date = Date()) -> UInt64? {
        guard shouldIntercept(now: now), hasQueuedCommand else { return nil }
        let consumedGeneration = generation
        close(.consumed)
        return consumedGeneration
    }

    @discardableResult
    public mutating func expire(generation expectedGeneration: UInt64, now: Date = Date()) -> Bool {
        guard generation == expectedGeneration,
              let expiresAt,
              now >= expiresAt else {
            return false
        }
        close(.expired)
        return true
    }

    public mutating func close(_ reason: CloseReason) {
        expiresAt = nil
        hasQueuedCommand = false
        lastCloseReason = reason
    }
}
