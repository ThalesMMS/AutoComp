import AppKit
import AutoCompCore

internal struct InlinePreviewLayout: Equatable {
    let origin: CGPoint
    let size: NSSize
    let source: InlinePreviewLayoutSource
    let inputFrame: NSRect?
    let ghostTextLayout: InlineGhostTextLayout?

    init(
        origin: CGPoint,
        size: NSSize,
        source: InlinePreviewLayoutSource,
        inputFrame: NSRect? = nil,
        ghostTextLayout: InlineGhostTextLayout? = nil
    ) {
        self.origin = origin
        self.size = size
        self.source = source
        self.inputFrame = inputFrame
        self.ghostTextLayout = ghostTextLayout
    }
}

internal enum InlinePreviewLayoutSource: String, Equatable {
    case exactAX
    case textBoxEstimate
}
