/// Canonical event names used by suggestion pipeline diagnostics.
public enum SuggestionDiagnosticsEventName {
    public static let pipelineStarted = "pipeline-started"
    public static let pipelineFinished = "pipeline-finished"
    public static let discardReason = "discard-reason"
    public static let providerModel = "provider-model"
    public static let providerLatencyMs = "provider-latency-ms"
}
