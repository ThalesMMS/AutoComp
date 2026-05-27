import ApplicationServices
import AppKit
import AutoCompCore
import Foundation

struct AXFocusSnapshot {
    let app: AppIdentity
    let bundleID: String
    let displayName: String
    let focusedElement: AXUIElement
    let focusedElementID: String
    let domain: String?
    let role: String?
    let subrole: String?
    let isGoogleDocsElement: Bool
    let isCodexComposerElement: Bool
    let selectedRange: NSRange?
    let fullText: String?
    let textLength: Int
    let textBeforeCursor: String?
    let textAfterCursor: String?
    let selectedText: String?
    let fullTextWindow: String?
}

struct FocusSnapshotTextWindow: Equatable {
    let textAfterCursor: String?
    let selectedText: String?
    let fullTextWindow: String?

    static func resolve(
        textAfterCursor: String?,
        selectedText: String?,
        fullText: String?,
        selectedRange: NSRange?,
        maxTextAfterCursorCharacters: Int = 1_500,
        maxSelectedTextCharacters: Int = 1_500,
        maxFullTextWindowCharacters: Int = 3_000
    ) -> FocusSnapshotTextWindow {
        FocusSnapshotTextWindow(
            textAfterCursor: limitedPrefix(
                textAfterCursor,
                maxCharacters: maxTextAfterCursorCharacters
            ),
            selectedText: limitedPrefix(
                selectedText,
                maxCharacters: maxSelectedTextCharacters
            ),
            fullTextWindow: textWindow(
                fullText: fullText,
                selectedRange: selectedRange,
                maxCharacters: maxFullTextWindowCharacters
            )
        )
    }

    private static func limitedPrefix(_ text: String?, maxCharacters: Int) -> String? {
        guard let text, !text.isEmpty, maxCharacters > 0 else {
            return nil
        }

        let nsText = text as NSString
        guard nsText.length > maxCharacters else {
            return text
        }
        return nsText.substring(to: maxCharacters)
    }

    private static func textWindow(
        fullText: String?,
        selectedRange: NSRange?,
        maxCharacters: Int
    ) -> String? {
        guard let fullText, !fullText.isEmpty, maxCharacters > 0 else {
            return nil
        }

        let nsText = fullText as NSString
        let textLength = nsText.length
        guard textLength > maxCharacters else {
            return fullText
        }

        let rawAnchor = selectedRange.map { $0.location + ($0.length / 2) } ?? textLength
        let anchor = min(max(0, rawAnchor), textLength)
        let preferredStart = max(0, anchor - (maxCharacters / 2))
        let start = min(preferredStart, max(0, textLength - maxCharacters))
        return nsText.substring(with: NSRange(location: start, length: maxCharacters))
    }
}

struct FocusSnapshotResolver {
    private let axHelper: AXHelper
    private let browserResolver: BrowserContextResolver

    init(
        axHelper: AXHelper = AXHelper(),
        browserResolver: BrowserContextResolver = BrowserContextResolver()
    ) {
        self.axHelper = axHelper
        self.browserResolver = browserResolver
    }

    func resolve() throws -> AXFocusSnapshot {
        guard AXIsProcessTrusted() else {
            throw AXTextContextError.accessibilityNotTrusted
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            throw AXTextContextError.noFrontmostApplication
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = axHelper.focusedElement(in: appElement) else {
            throw AXTextContextError.noFocusedElement
        }

        let displayName = app.localizedName ?? bundleID
        let activeDomain = browserResolver.activeDomain(for: bundleID)
        let focusedElement = resolvedTextElement(
            from: axHelper.resolvedFocusedElement(from: focused),
            appElement: appElement,
            bundleID: bundleID,
            activeDomain: activeDomain
        )
        guard !axHelper.isSecureField(focusedElement) else {
            throw AXTextContextError.secureOrUnsupportedField
        }

        let role = axHelper.stringAttribute(kAXRoleAttribute, from: focusedElement)
        let subrole = axHelper.stringAttribute(kAXSubroleAttribute, from: focusedElement)
        let isGoogleDocsElement = isGoogleDocsEditingElement(focusedElement)
            || hasGoogleDocsDocumentAncestor(focusedElement)
        let isCodexComposerElement = isCodexComposerElement(focusedElement, bundleID: bundleID)
        let domain = resolvedDomain(
            bundleID: bundleID,
            activeDomain: activeDomain,
            isGoogleDocsElement: isGoogleDocsElement
        )
        let selectedRange = axHelper.selectedRange(from: focusedElement)
        let fullText = axHelper.readableText(from: focusedElement)
        let textLength = axHelper.numberOfCharacters(from: focusedElement)
            ?? fullText.map { ($0 as NSString).length }
            ?? selectedRange.map { $0.location + $0.length }
            ?? 0
        let textBeforeCursor = axHelper.textBeforeCursor(
            from: focusedElement,
            selectedRange: selectedRange,
            fullText: fullText
        )
        let textWindow = FocusSnapshotTextWindow.resolve(
            textAfterCursor: axHelper.textAfterCursor(
                from: focusedElement,
                selectedRange: selectedRange,
                fullText: fullText,
                textLength: textLength
            ),
            selectedText: axHelper.selectedText(
                from: focusedElement,
                selectedRange: selectedRange,
                fullText: fullText
            ),
            fullText: fullText,
            selectedRange: selectedRange
        )

        return AXFocusSnapshot(
            app: AppIdentity(
                bundleID: bundleID,
                displayName: displayName,
                processID: app.processIdentifier
            ),
            bundleID: bundleID,
            displayName: displayName,
            focusedElement: focusedElement,
            focusedElementID: "\(app.processIdentifier)-\(Unmanaged.passUnretained(focusedElement).toOpaque())",
            domain: domain,
            role: role,
            subrole: subrole,
            isGoogleDocsElement: isGoogleDocsElement,
            isCodexComposerElement: isCodexComposerElement,
            selectedRange: selectedRange,
            fullText: fullText,
            textLength: textLength,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textWindow.textAfterCursor,
            selectedText: textWindow.selectedText,
            fullTextWindow: textWindow.fullTextWindow
        )
    }

    private func resolvedTextElement(
        from focusedElement: AXUIElement,
        appElement: AXUIElement,
        bundleID: String,
        activeDomain: String?
    ) -> AXUIElement {
        guard bundleID == "com.google.Chrome",
              !isTextReadable(from: focusedElement) else {
            return focusedElement
        }

        if let descendant = axHelper.firstDescendant(of: focusedElement, matching: isGoogleDocsReadableTextElement)
            ?? axHelper.firstDescendant(of: appElement, matching: isGoogleDocsReadableTextElement) {
            GeometryDebug.log("ax-fallback source=google-docs-descendant domain=\(activeDomain ?? "nil")")
            return descendant
        }

        return focusedElement
    }

    private func resolvedDomain(
        bundleID: String,
        activeDomain: String?,
        isGoogleDocsElement: Bool
    ) -> String? {
        var domain = activeDomain
        if domain == nil,
           bundleID == "com.google.Chrome",
           isGoogleDocsElement {
            domain = "docs.google.com"
        }
        return domain
    }

    private func isGoogleDocsDomain(_ domain: String?) -> Bool {
        domain == "docs.google.com"
    }

    private func isCodexComposerElement(_ element: AXUIElement, bundleID: String) -> Bool {
        guard bundleID == "com.openai.codex",
              axHelper.stringAttribute(kAXRoleAttribute, from: element) == "AXTextArea" else {
            return false
        }

        let classes = axHelper.stringListAttribute("AXDOMClassList", from: element)
        return classes.contains("ProseMirror")
            || classes.contains("ProseMirror-focused")
    }

    private func isGoogleDocsEditingElement(_ element: AXUIElement) -> Bool {
        let role = axHelper.stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let description = axHelper.stringAttribute(kAXDescriptionAttribute, from: element) ?? ""
        return role == "AXTextArea"
            && (description.localizedCaseInsensitiveContains("document")
                || description.localizedCaseInsensitiveContains("documento")
            )
    }

    private func isGoogleDocsReadableTextElement(_ element: AXUIElement) -> Bool {
        guard isGoogleDocsEditingElement(element),
              isTextReadable(from: element) else {
            return false
        }
        return true
    }

    private func isTextReadable(from element: AXUIElement) -> Bool {
        if axHelper.readableText(from: element) != nil {
            return true
        }
        if let numberOfCharacters = axHelper.numberOfCharacters(from: element),
           numberOfCharacters > 0 {
            return true
        }
        return axHelper.selectedRange(from: element) != nil
    }

    private func hasGoogleDocsDocumentAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<6 {
            let role = axHelper.stringAttribute(kAXRoleAttribute, from: current) ?? ""
            let title = axHelper.stringAttribute(kAXTitleAttribute, from: current) ?? ""
            if role == "AXWebArea",
               title.localizedCaseInsensitiveContains("Google Docs") {
                return true
            }

            guard let parent = axHelper.parentElement(for: current) else {
                return false
            }
            current = parent
        }
        return false
    }
}
