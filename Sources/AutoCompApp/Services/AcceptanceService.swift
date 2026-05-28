import AppKit
import AutoCompCore
import Foundation

enum AcceptanceError: Error {
    case insertionFailed
    case riskyHostReturnBlocked
}

enum AcceptanceInsertionStrategy: Equatable {
    case singleUnicodeEvent
    case perCharacterEvents
    case clipboard
}

struct AcceptanceInsertionPolicy: Equatable {
    var singleUnicodeFastPathEnabled = true
    var keyboardEventUTF16Limit = 64
    var singleUnicodeIncompatibleBundleIDs: Set<String> = []
    var clipboardPreferredBundleIDs: Set<String> = []
    var returnBlockedBundleIDs = RiskyHostAppPolicy.chatBundleIDs

    static var productionDefault: AcceptanceInsertionPolicy {
        AcceptanceInsertionPolicy(
            singleUnicodeFastPathEnabled: ProcessInfo.processInfo.environment["AUTOCOMP_DISABLE_SINGLE_UNICODE_INSERTION"] != "1"
        )
    }

    func strategy(for text: String, bundleID: String?) -> AcceptanceInsertionStrategy {
        if text.utf16.count > keyboardEventUTF16Limit {
            return .clipboard
        }

        if let bundleID, clipboardPreferredBundleIDs.contains(bundleID) {
            return .clipboard
        }

        guard singleUnicodeFastPathEnabled else {
            return .perCharacterEvents
        }

        if let bundleID, singleUnicodeIncompatibleBundleIDs.contains(bundleID) {
            return .perCharacterEvents
        }

        return .singleUnicodeEvent
    }

    func allowsInsertion(of text: String, bundleID: String?) -> Bool {
        guard let bundleID, returnBlockedBundleIDs.contains(bundleID) else {
            return true
        }
        return !RiskyHostAppPolicy.containsReturn(text)
    }
}

struct AcceptanceUnicodePayload {
    static func utf16Units(for text: String) -> [UniChar] {
        Array(text.utf16)
    }
}

protocol AcceptanceKeyboardEventPosting: AnyObject {
    func postUnicodeString(_ units: [UniChar]) -> Bool
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool
}

final class CGEventAcceptanceKeyboardEventPoster: AcceptanceKeyboardEventPosting {
    func postUnicodeString(_ units: [UniChar]) -> Bool {
        guard !units.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }

        units.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: baseAddress)
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

struct PreservedPasteboardItem: Equatable, Codable {
    let dataByType: [NSPasteboard.PasteboardType: Data]

    init(dataByType: [NSPasteboard.PasteboardType: Data]) {
        self.dataByType = dataByType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encodedItems = try container.decode([String: Data].self)
        self.dataByType = Dictionary(
            uniqueKeysWithValues: encodedItems.map { key, data in
                (NSPasteboard.PasteboardType(key), data)
            }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let encodedItems = Dictionary(
            uniqueKeysWithValues: dataByType.map { type, data in
                (type.rawValue, data)
            }
        )
        try container.encode(encodedItems)
    }
}

protocol AcceptancePasteboard: AnyObject {
    func preservedItems() -> [PreservedPasteboardItem]?
    func clearContents()
    func setString(_ text: String, recoveryMarkerID: String?)
    func writeItems(_ items: [PreservedPasteboardItem])
    func containsRecoveryMarker(id: String) -> Bool
}

final class SystemAcceptancePasteboard: AcceptancePasteboard {
    private static let recoveryMarkerType = NSPasteboard.PasteboardType("com.autocomp.pending-pasteboard-insertion")
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func preservedItems() -> [PreservedPasteboardItem]? {
        pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PreservedPasteboardItem(dataByType: dataByType)
        }
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    func setString(_ text: String, recoveryMarkerID: String?) {
        pasteboard.setString(text, forType: .string)
        if let recoveryMarkerID {
            pasteboard.setString(recoveryMarkerID, forType: Self.recoveryMarkerType)
        }
    }

    func writeItems(_ items: [PreservedPasteboardItem]) {
        let pasteboardItems = items.map { preservedItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in preservedItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    func containsRecoveryMarker(id: String) -> Bool {
        pasteboard.string(forType: Self.recoveryMarkerType) == id
    }
}

@MainActor
protocol ShortcutLeakRepairing: AnyObject {
    func replaceLeakedShortcutSuffix(
        length: Int,
        withNextWordsFrom suggestion: inout Suggestion
    ) async throws -> String?
}

@MainActor
final class AcceptanceService: TextInserter, ShortcutLeakRepairing {
    private let inputSuppressionController: InputSuppressionController?
    private let insertionPolicy: AcceptanceInsertionPolicy
    private let keyboardEventPoster: AcceptanceKeyboardEventPosting
    private let pasteboard: AcceptancePasteboard
    private let pasteboardRecoveryStore: PasteboardInsertionRecoveryStore?
    private let frontmostBundleIDProvider: () -> String?
    private let clipboardRestoreDelay: TimeInterval

    init(
        inputSuppressionController: InputSuppressionController? = nil,
        insertionPolicy: AcceptanceInsertionPolicy = .productionDefault,
        keyboardEventPoster: AcceptanceKeyboardEventPosting = CGEventAcceptanceKeyboardEventPoster(),
        pasteboard: AcceptancePasteboard = SystemAcceptancePasteboard(),
        pasteboardRecoveryStore: PasteboardInsertionRecoveryStore? = PasteboardInsertionRecoveryStore(),
        frontmostBundleIDProvider: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        clipboardRestoreDelay: TimeInterval = 0.2
    ) {
        self.inputSuppressionController = inputSuppressionController
        self.insertionPolicy = insertionPolicy
        self.keyboardEventPoster = keyboardEventPoster
        self.pasteboard = pasteboard
        self.pasteboardRecoveryStore = pasteboardRecoveryStore
        self.frontmostBundleIDProvider = frontmostBundleIDProvider
        self.clipboardRestoreDelay = clipboardRestoreDelay
    }

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptNextWord() else {
            return nil
        }
        try insert(token)
        return token
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptAll() else {
            return nil
        }
        try insert(token)
        return token
    }

    func replaceLeakedShortcutSuffix(
        length: Int,
        withNextWordsFrom suggestion: inout Suggestion
    ) async throws -> String? {
        guard length > 0 else {
            return nil
        }
        for _ in 0..<length {
            try pressKey(0x33)
        }

        var acceptedText = ""
        for _ in 0..<length {
            guard let token = suggestion.acceptNextWord() else {
                break
            }
            acceptedText += token
        }

        guard !acceptedText.isEmpty else {
            return nil
        }
        try insert(acceptedText)
        return acceptedText
    }

    func recoverPendingPasteboardInsertionIfNeeded() {
        guard let snapshot = pasteboardRecoveryStore?.loadFreshSnapshot() else {
            return
        }

        guard pasteboard.containsRecoveryMarker(id: snapshot.id) else {
            try? pasteboardRecoveryStore?.delete(matchingID: snapshot.id)
            GeometryDebug.log("pasteboard-recovery skipped reason=marker-mismatch")
            return
        }

        restore(previousItems: snapshot.previousItems, recoveryID: snapshot.id)
        GeometryDebug.log("pasteboard-recovery restored")
    }

    private func insert(_ text: String) throws {
        guard !text.isEmpty else {
            return
        }

        let bundleID = frontmostBundleIDProvider()
        guard insertionPolicy.allowsInsertion(of: text, bundleID: bundleID) else {
            GeometryDebug.log("insertion blocked reason=chat-return bundle=\(bundleID ?? "nil") utf16Length=\(text.utf16.count)")
            throw AcceptanceError.riskyHostReturnBlocked
        }

        switch insertionPolicy.strategy(for: text, bundleID: bundleID) {
        case .singleUnicodeEvent:
            if insertBySingleUnicodeCGEvent(text) {
                return
            }
            GeometryDebug.log("insertion-strategy fallback=per-character reason=single-unicode-failed utf16Length=\(text.utf16.count)")
            try insertByKeyboardEvents(text)
        case .perCharacterEvents:
            try insertByKeyboardEvents(text)
        case .clipboard:
            try insertByClipboard(text)
        }
    }

    private func pressKey(_ keyCode: CGKeyCode) throws {
        guard keyboardEventPoster.postKey(keyCode, flags: []) else {
            throw AcceptanceError.insertionFailed
        }
        registerSyntheticKeyboardPairs(1)
    }

    private func insertBySingleUnicodeCGEvent(_ text: String) -> Bool {
        let units = AcceptanceUnicodePayload.utf16Units(for: text)
        guard keyboardEventPoster.postUnicodeString(units) else {
            return false
        }
        registerSyntheticKeyboardPairs(1)
        GeometryDebug.log("insertion-strategy strategy=single-unicode utf16Length=\(units.count)")
        return true
    }

    private func insertByKeyboardEvents(_ text: String) throws {
        let units = AcceptanceUnicodePayload.utf16Units(for: text)
        var postedPairCount = 0
        for unit in units {
            guard keyboardEventPoster.postUnicodeString([unit]) else {
                registerSyntheticKeyboardPairs(postedPairCount)
                throw AcceptanceError.insertionFailed
            }
            postedPairCount += 1
        }
        registerSyntheticKeyboardPairs(postedPairCount)
        GeometryDebug.log("insertion-strategy strategy=per-character utf16Length=\(units.count)")
    }

    private func insertByClipboard(_ text: String) throws {
        let previousItems = pasteboard.preservedItems()
        let recoveryID = UUID().uuidString
        let recoverySnapshot = PasteboardInsertionRecoverySnapshot(
            id: recoveryID,
            createdAt: Date(),
            previousItems: previousItems
        )
        let recoveryMarkerID: String?
        do {
            try pasteboardRecoveryStore?.save(recoverySnapshot)
            recoveryMarkerID = pasteboardRecoveryStore == nil ? nil : recoveryID
        } catch {
            recoveryMarkerID = nil
            GeometryDebug.log("pasteboard-recovery skipped reason=snapshot-save-failed")
        }
        pasteboard.clearContents()
        pasteboard.setString(text, recoveryMarkerID: recoveryMarkerID)

        guard keyboardEventPoster.postKey(0x09, flags: .maskCommand) else {
            restore(previousItems: previousItems, recoveryID: recoveryMarkerID)
            throw AcceptanceError.insertionFailed
        }

        registerSyntheticKeyboardPairs(1)
        GeometryDebug.log("insertion-strategy strategy=clipboard utf16Length=\(text.utf16.count)")

        if clipboardRestoreDelay <= 0 {
            restore(previousItems: previousItems, recoveryID: recoveryMarkerID)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                self.restore(previousItems: previousItems, recoveryID: recoveryMarkerID)
            }
        }
    }

    private func restore(previousItems: [PreservedPasteboardItem]?, recoveryID: String?) {
        if let recoveryID,
           !pasteboard.containsRecoveryMarker(id: recoveryID) {
            try? pasteboardRecoveryStore?.delete(matchingID: recoveryID)
            GeometryDebug.log("pasteboard-restore skipped reason=marker-mismatch")
            return
        }

        pasteboard.clearContents()
        if let previousItems {
            pasteboard.writeItems(previousItems)
        }
        if let recoveryID {
            try? pasteboardRecoveryStore?.delete(matchingID: recoveryID)
        }
    }

    private func registerSyntheticKeyboardPairs(_ count: Int) {
        inputSuppressionController?.registerSyntheticInsertion(
            expectedKeyDownCount: count,
            expectedKeyUpCount: count
        )
    }
}
