import Foundation

/// Pipeline step that decides whether visual context should be considered for the current request.
///
/// This step is intentionally limited to *eligibility* checks; it does not perform any screenshot
/// capture or OCR. The orchestration layer may use the typed decision to trigger capture.
public struct VisualContextEligibilityStep<Payload: Sendable & Equatable>: SuggestionPipeline.Step {
    public typealias Context = SuggestionPipeline.RequestContext
    public typealias Decision = SuggestionPipeline.VisualContextEligibilityDecision

    public struct Inputs: Sendable {
        public var visualContextEnabled: @Sendable () -> Bool
        public var visualContextProviderAvailable: @Sendable () -> Bool
        public var screenRecordingAllowed: @Sendable () -> Bool
        public var appDomainAllowed: @Sendable () -> Bool
        public var fieldSecure: @Sendable () -> Bool
        public var autocompleteEligible: @Sendable () -> Bool

        public init(
            visualContextEnabled: @escaping @Sendable () -> Bool,
            visualContextProviderAvailable: @escaping @Sendable () -> Bool,
            screenRecordingAllowed: @escaping @Sendable () -> Bool = { true },
            appDomainAllowed: @escaping @Sendable () -> Bool = { true },
            fieldSecure: @escaping @Sendable () -> Bool = { false },
            autocompleteEligible: @escaping @Sendable () -> Bool = { true }
        ) {
            self.visualContextEnabled = visualContextEnabled
            self.visualContextProviderAvailable = visualContextProviderAvailable
            self.screenRecordingAllowed = screenRecordingAllowed
            self.appDomainAllowed = appDomainAllowed
            self.fieldSecure = fieldSecure
            self.autocompleteEligible = autocompleteEligible
        }
    }

    private let inputs: Inputs

    public init(inputs: Inputs) {
        self.inputs = inputs
    }

    public func handle(context: inout Context) async -> SuggestionPipeline.Outcome<Payload> {
        let enabled = inputs.visualContextEnabled()
        let providerAvailable = inputs.visualContextProviderAvailable()
        let screenRecordingAllowed = inputs.screenRecordingAllowed()
        let appDomainAllowed = inputs.appDomainAllowed()
        let fieldSecure = inputs.fieldSecure()
        let autocompleteEligible = inputs.autocompleteEligible()

        let decision: Decision
        if !enabled {
            decision = .ineligible(reason: "disabled")
        } else if !providerAvailable {
            decision = .ineligible(reason: "unavailable")
        } else if !screenRecordingAllowed {
            decision = .ineligible(reason: "screen-recording-off")
        } else if !appDomainAllowed {
            decision = .ineligible(reason: "app-domain-disabled")
        } else if fieldSecure {
            decision = .ineligible(reason: "secure-field")
        } else if !autocompleteEligible {
            decision = .ineligible(reason: "autocomplete-ineligible")
        } else {
            decision = .eligible
        }

        context.visualContextEligibilityDecision = decision
        return .continue
    }
}
