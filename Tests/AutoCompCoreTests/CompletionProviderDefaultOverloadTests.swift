import Foundation
import XCTest
@testable import AutoCompCore

final class CompletionProviderDefaultOverloadTests: XCTestCase {
    func testClipboardAwareProviderGetsDefaultShorterOverloads() async throws {
        let provider = MinimalClipboardProvider()
        let context = Self.textContext()

        let suggestion = try await provider.complete(context: context)

        XCTAssertEqual(suggestion.visibleText, "clipboard")
        let call = await provider.recordedCall()
        XCTAssertEqual(call?.privacySettings, PrivacySettings())
        XCTAssertNil(call?.visualContext)
        XCTAssertNil(call?.clipboardContext)
    }

    func testPersonalizationAwareProviderGetsDefaultShorterOverloads() async throws {
        let provider = MinimalPersonalizationProvider()
        let context = Self.textContext()

        let suggestion = try await provider.complete(context: context)

        XCTAssertEqual(suggestion.visibleText, "personalized")
        let call = await provider.recordedCall()
        XCTAssertEqual(call?.privacySettings, PrivacySettings())
        XCTAssertNil(call?.visualContext)
        XCTAssertNil(call?.clipboardContext)
        XCTAssertEqual(call?.personalizationSamples, [])
    }

    func testMultiplePersonalizationProviderGetsDefaultOptionsOverload() async throws {
        let provider = MinimalMultiplePersonalizationProvider()
        let context = Self.textContext()
        let options = CompletionOptions(suggestionCount: 3)

        let suggestions = try await provider.complete(
            context: context,
            privacySettings: PrivacySettings(),
            visualContext: nil,
            clipboardContext: nil,
            options: options
        )

        XCTAssertEqual(suggestions.map(\.visibleText), ["one", "two", "three"])
        let call = await provider.recordedMultipleCall()
        XCTAssertEqual(call?.personalizationSamples, [])
        XCTAssertEqual(call?.options, options)
    }

    func testProviderForwardingLaddersLiveInProtocolExtensions() throws {
        let protocolsSource = try sourceFile("Sources/AutoCompCore/Protocols/AutocompleteProtocols.swift")

        for requiredExtension in [
            "public extension VisualContextAwareCompletionProvider",
            "public extension ClipboardContextAwareCompletionProvider",
            "public extension PersonalizationContextAwareCompletionProvider",
            "public extension MultiplePersonalizationContextAwareCompletionProvider"
        ] {
            XCTAssertTrue(protocolsSource.contains(requiredExtension), "Missing default overload extension: \(requiredExtension)")
        }

        for relativePath in [
            "Sources/AutoCompCore/Services/CompletionProviderRouter.swift",
            "Sources/AutoCompCore/Services/RemoteCompletionProvider.swift",
            "Sources/AutoCompCore/Services/LocalLlamaCompletionProvider.swift",
            "Sources/AutoCompCore/Services/ConstrainedLocalCompletionProvider.swift",
            "Sources/AutoCompCore/Services/AppleFoundationCompletionProvider.swift",
            "Sources/AutoCompApp/App/AutoCompAppEnvironment.swift",
            "Tests/AutoCompAppTests/TestFixtures.swift",
            "Tests/AutoCompAppTests/SuggestionEngineAcceptanceTests.swift",
            "Tests/AutoCompCoreTests/ProviderInvocationStepTests.swift",
            "Tests/AutoCompCoreTests/CompletionProviderRouterTests.swift"
        ] {
            let source = try sourceFile(relativePath)
            XCTAssertFalse(
                source.contains("try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)"),
                "Remove complete(context:) forwarding ladder from \(relativePath)"
            )
            XCTAssertFalse(
                source.contains("try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil, clipboardContext: nil)"),
                "Remove complete(context:) forwarding ladder from \(relativePath)"
            )
            XCTAssertFalse(
                source.contains("privacySettings: privacySettings,\n            visualContext: visualContext,\n            clipboardContext: nil"),
                "Remove visualContext forwarding ladder from \(relativePath)"
            )
            XCTAssertFalse(
                source.contains("clipboardContext: clipboardContext,\n            personalizationSamples: []"),
                "Remove personalization forwarding ladder from \(relativePath)"
            )
        }
    }

    private static func textContext() -> TextContext {
        TextContext(
            app: .init(bundleID: "com.test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "hello",
            textAfterCursor: nil
        )
    }

}

private actor MinimalClipboardProvider: ClipboardContextAwareCompletionProvider {
    private var call: ClipboardCall?

    func recordedCall() -> ClipboardCall? {
        call
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        call = ClipboardCall(
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )
        return Suggestion(baseContextID: context.id, visibleText: "clipboard", latencyMs: 0)
    }
}

private actor MinimalPersonalizationProvider: PersonalizationContextAwareCompletionProvider {
    private var call: PersonalizationCall?

    func recordedCall() -> PersonalizationCall? {
        call
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion {
        call = PersonalizationCall(
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: personalizationSamples
        )
        return Suggestion(baseContextID: context.id, visibleText: "personalized", latencyMs: 0)
    }
}

private actor MinimalMultiplePersonalizationProvider: MultiplePersonalizationContextAwareCompletionProvider {
    private var multipleCall: MultiplePersonalizationCall?

    func recordedMultipleCall() -> MultiplePersonalizationCall? {
        multipleCall
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion {
        Suggestion(baseContextID: context.id, visibleText: "single", latencyMs: 0)
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample],
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        multipleCall = MultiplePersonalizationCall(
            personalizationSamples: personalizationSamples,
            options: options
        )
        return (1...options.suggestionCount).map { index in
            Suggestion(baseContextID: context.id, visibleText: ["one", "two", "three"][index - 1], latencyMs: 0)
        }
    }
}

private struct ClipboardCall: Equatable {
    let privacySettings: PrivacySettings
    let visualContext: VisualContextSnapshot?
    let clipboardContext: ClipboardContextSnapshot?
}

private struct PersonalizationCall: Equatable {
    let privacySettings: PrivacySettings
    let visualContext: VisualContextSnapshot?
    let clipboardContext: ClipboardContextSnapshot?
    let personalizationSamples: [PersonalizationSample]
}

private struct MultiplePersonalizationCall: Equatable {
    let personalizationSamples: [PersonalizationSample]
    let options: CompletionOptions
}
