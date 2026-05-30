import Foundation

private let pasteboardLogger = AutoCompLogger(category: "pasteboard")

/// A lightweight utility for pasteboard-based insertion flows.
///
/// The transaction captures a snapshot of the current pasteboard contents and can later restore
/// that snapshot *only if* the pasteboard still appears to contain the temporary payload written
/// by AutoComp (as indicated by the recovery marker).
///
/// This helps ensure we don't clobber newer user clipboard data if the user copies something
/// while a paste-based insertion is in flight.
struct PasteboardTransaction: Sendable {
    let recoveryID: String
    let previousItems: [PreservedPasteboardItem]?

    init(
        recoveryID: String = UUID().uuidString,
        previousItems: [PreservedPasteboardItem]?
    ) {
        self.recoveryID = recoveryID
        self.previousItems = previousItems
    }

    static func begin(using pasteboard: AcceptancePasteboard) -> PasteboardTransaction {
        PasteboardTransaction(previousItems: pasteboard.preservedItems())
    }

    func writeTemporaryString(_ text: String, to pasteboard: AcceptancePasteboard, includeRecoveryMarker: Bool) {
        pasteboard.clearContents()
        pasteboard.setString(text, recoveryMarkerID: includeRecoveryMarker ? recoveryID : nil)
    }

    func restore(using pasteboard: AcceptancePasteboard, recoveryStore: PasteboardInsertionRecoveryStore?) {
        if let recoveryStore {
            // If the pasteboard no longer has our marker, a user (or another app) has likely
            // changed the clipboard. Don't overwrite newer data.
            guard pasteboard.containsRecoveryMarker(id: recoveryID) else {
                try? recoveryStore.delete(matchingID: recoveryID)
                pasteboardLogger.info("pasteboard-restore skipped reason=marker-mismatch")
                return
            }
        }

        pasteboard.clearContents()
        if let previousItems {
            pasteboard.writeItems(previousItems)
        }
        if let recoveryStore {
            try? recoveryStore.delete(matchingID: recoveryID)
        }

        pasteboardLogger.info("pasteboard-restore restored")
    }
}
