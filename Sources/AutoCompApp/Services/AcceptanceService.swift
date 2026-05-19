import AppKit
import AutoCompCore
import Foundation

enum AcceptanceError: Error {
    case insertionFailed
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
        try insertByClipboard(token)
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

    private func insert(_ text: String) throws {
        if text.count <= 64 {
            try insertByKeyboardEvents(text)
        } else {
            try insertByClipboard(text)
        }
    }

    private func pressKey(_ keyCode: CGKeyCode) throws {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw AcceptanceError.insertionFailed
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func insertByKeyboardEvents(_ text: String) throws {
        for scalar in text.utf16 {
            var value = scalar
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw AcceptanceError.insertionFailed
            }
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func insertByClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let commandDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            restore(pasteboard: pasteboard, previousItems: previousItems)
            throw AcceptanceError.insertionFailed
        }

        commandDown.flags = .maskCommand
        commandUp.flags = .maskCommand
        commandDown.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.restore(pasteboard: pasteboard, previousItems: previousItems)
        }
    }

    private func restore(pasteboard: NSPasteboard, previousItems: [NSPasteboardItem]?) {
        pasteboard.clearContents()
        if let previousItems {
            pasteboard.writeObjects(previousItems)
        }
    }
}
