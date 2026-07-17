import Foundation

public struct FrozenPromptSideContext: Equatable, Sendable {
    public let visualContext: VisualContextSnapshot?
    public let clipboardContext: ClipboardContextSnapshot?
    public let personalizationSamples: [PersonalizationSample]
    public let languageHint: String?
    public let captureSources: Set<TextCaptureSource>

    public init(
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample],
        languageHint: String? = nil,
        captureSources: Set<TextCaptureSource> = []
    ) {
        self.visualContext = visualContext
        self.clipboardContext = clipboardContext
        self.personalizationSamples = personalizationSamples
        self.languageHint = languageHint
        self.captureSources = captureSources
    }
}

public struct FrozenPromptSideContextResolution: Equatable, Sendable {
    public let context: FrozenPromptSideContext
    public let resetReason: LlamaPromptCacheResetReason?

    public init(context: FrozenPromptSideContext, resetReason: LlamaPromptCacheResetReason?) {
        self.context = context
        self.resetReason = resetReason
    }
}

public actor FrozenPromptSideContextStore {
    private struct State: Sendable {
        var field: LlamaPromptCache.Field
        var privacySettings: PrivacySettings
        var context: FrozenPromptSideContext
        var expiresAt: Date
    }

    private let ttl: TimeInterval
    private var state: State?

    public init(ttl: TimeInterval = 5) {
        self.ttl = max(0.25, ttl)
    }

    public func resolve(
        textContext: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample],
        now: Date = Date()
    ) -> FrozenPromptSideContextResolution {
        let lowTrust = textContext.captureSources.contains(.keystrokeBufferLowTrust)
        if lowTrust {
            let hadState = state != nil
            state = nil
            return FrozenPromptSideContextResolution(
                context: FrozenPromptSideContext(
                    visualContext: nil,
                    clipboardContext: nil,
                    personalizationSamples: [],
                    languageHint: textContext.languageHint,
                    captureSources: textContext.captureSources
                ),
                resetReason: hadState ? .sideContextChanged : nil
            )
        }

        let field = LlamaPromptCache.Field(context: textContext)
        let incoming = sanitizedContext(
            textContext: textContext,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: personalizationSamples
        )
        guard var current = state else {
            state = makeState(field: field, privacySettings: privacySettings, context: incoming, now: now)
            return FrozenPromptSideContextResolution(context: incoming, resetReason: nil)
        }
        guard current.field == field else {
            state = makeState(field: field, privacySettings: privacySettings, context: incoming, now: now)
            return FrozenPromptSideContextResolution(context: incoming, resetReason: .fieldChanged)
        }
        guard current.privacySettings == privacySettings else {
            state = makeState(field: field, privacySettings: privacySettings, context: incoming, now: now)
            return FrozenPromptSideContextResolution(context: incoming, resetReason: .privacyChanged)
        }
        guard now < current.expiresAt else {
            state = makeState(field: field, privacySettings: privacySettings, context: incoming, now: now)
            return FrozenPromptSideContextResolution(context: incoming, resetReason: .ttlExpired)
        }

        if clipboardMeaningfullyChanged(from: current.context.clipboardContext, to: incoming.clipboardContext) {
            current.context = FrozenPromptSideContext(
                visualContext: current.context.visualContext,
                clipboardContext: incoming.clipboardContext,
                personalizationSamples: current.context.personalizationSamples,
                languageHint: current.context.languageHint,
                captureSources: current.context.captureSources
            )
            current.expiresAt = now.addingTimeInterval(ttl)
            state = current
            return FrozenPromptSideContextResolution(context: current.context, resetReason: .sideContextChanged)
        }

        state = current
        return FrozenPromptSideContextResolution(context: current.context, resetReason: nil)
    }

    public func reset() {
        state = nil
    }

    private func makeState(
        field: LlamaPromptCache.Field,
        privacySettings: PrivacySettings,
        context: FrozenPromptSideContext,
        now: Date
    ) -> State {
        State(
            field: field,
            privacySettings: privacySettings,
            context: context,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    private func sanitizedContext(
        textContext: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) -> FrozenPromptSideContext {
        FrozenPromptSideContext(
            visualContext: privacySettings.screenContextEnabled ? visualContext : nil,
            clipboardContext: privacySettings.clipboardContextEnabled ? clipboardContext : nil,
            personalizationSamples: privacySettings.localPersonalizationEnabled ? personalizationSamples : [],
            languageHint: textContext.languageHint,
            captureSources: textContext.captureSources
        )
    }

    private func clipboardMeaningfullyChanged(
        from previous: ClipboardContextSnapshot?,
        to next: ClipboardContextSnapshot?
    ) -> Bool {
        switch (previous, next) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let previous), .some(let next)):
            return previous.summary != next.summary
                || previous.status != next.status
                || previous.captureSources != next.captureSources
        }
    }
}
