import Foundation

/// Pipeline step that decides whether visual context should be considered for the current request.
///
/// This step is intentionally limited to *eligibility* checks; it does not perform any screenshot
/// capture or OCR. The orchestration layer may use the stored decision to trigger capture.
public struct VisualContextEligibilityStep<Payload: Sendable & Equatable>: SuggestionPipeline.Step {
    public typealias Context = SuggestionPipeline.RequestContext

    public struct Inputs: Sendable {
        public var visualContextEnabled: @Sendable () -> Bool
        public var visualContextProviderAvailable: @Sendable () -> Bool

        public init(
            visualContextEnabled: @escaping @Sendable () -> Bool,
            visualContextProviderAvailable: @escaping @Sendable () -> Bool
        ) {
            self.visualContextEnabled = visualContextEnabled
            self.visualContextProviderAvailable = visualContextProviderAvailable
        }
    }

    public static var decisionUserInfoKey: String { "visualContext.eligibility" }

    public enum Decision: Sendable, Equatable {
        case eligible
        case ineligible(reason: String)
    }

    private let inputs: Inputs

    public init(inputs: Inputs) {
        self.inputs = inputs
    }

    public func handle(context: inout Context) async -> SuggestionPipeline.Outcome<Payload> {
        let enabled = inputs.visualContextEnabled()
        let providerAvailable = inputs.visualContextProviderAvailable()

        let decision: Decision
        if !enabled {
            decision = .ineligible(reason: "disabled")
        } else if !providerAvailable {
            decision = .ineligible(reason: "unavailable")
        } else {
            decision = .eligible
        }

        context.userInfo[Self.decisionUserInfoKey] = decision
        return .continue
    }
}
