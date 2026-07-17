public enum CompletionSystemPrompts {
    public static let continuation = "You are AutoComp, a low-latency autocomplete engine. Return only the user's likely next words. Do not explain."
    public static let fillInMiddle = "You are AutoComp, a low-latency autocomplete engine. Fill the cursor gap and return only the text to insert. Do not repeat suffix text or explain."

    public static func prompt(for mode: CompletionRequestMode) -> String {
        switch mode {
        case .continuation:
            continuation
        case .fillInMiddle:
            fillInMiddle
        }
    }
}
