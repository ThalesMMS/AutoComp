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
    let domainResolution: BrowserDomainResolution
    let role: String?
    let subrole: String?
    let isGoogleDocsElement: Bool
    let isCodexComposerElement: Bool
    let selectedRange: NSRange?
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

    static func limitedPrefix(_ text: String?, maxCharacters: Int) -> String? {
        guard let text, !text.isEmpty, maxCharacters > 0 else {
            return nil
        }

        guard (text as NSString).length > maxCharacters else {
            return text
        }
        let prefix = UTF16TextRange.prefix(text, endingAt: maxCharacters)
        return prefix.isEmpty ? nil : prefix
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
        let window = UTF16TextRange.substring(
            fullText,
            enclosedBy: NSRange(location: start, length: maxCharacters)
        )
        return window?.isEmpty == false ? window : nil
    }
}

struct FocusSnapshotTextCapture: Equatable {
    let textLength: Int
    let textBeforeCursor: String?
    let textAfterCursor: String?
    let selectedText: String?
    let fullTextWindow: String?

    static func resolve(
        selectedRange: NSRange?,
        textLength: Int?,
        readRange: (CFRange) -> String?,
        readFullText: () -> String?,
        maxTextAfterCursorCharacters: Int = 1_500,
        maxSelectedTextCharacters: Int = 1_500,
        maxFullTextWindowCharacters: Int = 3_000
    ) -> FocusSnapshotTextCapture {
        let validSelection = selectedRange.flatMap { range -> NSRange? in
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
            return range
        }
        let provisionalLength = max(
            0,
            textLength ?? validSelection.map { $0.location + $0.length } ?? 0
        )
        let prefixRange = validSelection.map {
            CFRange(location: 0, length: $0.location)
        }
        let suffixRange = validSelection.map { range in
            let start = min(provisionalLength, range.location + range.length)
            return CFRange(
                location: start,
                length: min(max(0, provisionalLength - start), max(0, maxTextAfterCursorCharacters))
            )
        }
        let selectionRange = validSelection.map {
            CFRange(location: $0.location, length: min($0.length, max(0, maxSelectedTextCharacters)))
        }
        let windowRange = textWindowRange(
            textLength: provisionalLength,
            selectedRange: validSelection,
            maxCharacters: maxFullTextWindowCharacters
        )

        let rangedPrefix = prefixRange.flatMap(readRange)
        let rangedSuffix = suffixRange.flatMap { $0.length > 0 ? readRange($0) : "" }
        let rangedSelection = selectionRange.flatMap { $0.length > 0 ? readRange($0) : "" }
        let rangedWindow = windowRange.flatMap(readRange)
        let needsFullText = validSelection == nil
            || textLength == nil
            || rangedPrefix == nil
            || (suffixRange?.length ?? 0) > 0 && rangedSuffix == nil
            || (selectionRange?.length ?? 0) > 0 && rangedSelection == nil
        let fullText = needsFullText ? readFullText() : nil
        let effectiveLength = fullText.map { ($0 as NSString).length } ?? provisionalLength
        let fallbackWindow = FocusSnapshotTextWindow.resolve(
            textAfterCursor: fullText.flatMap { suffix(of: $0, selectedRange: validSelection) },
            selectedText: fullText.flatMap { selection(in: $0, selectedRange: validSelection) },
            fullText: fullText,
            selectedRange: validSelection,
            maxTextAfterCursorCharacters: maxTextAfterCursorCharacters,
            maxSelectedTextCharacters: maxSelectedTextCharacters,
            maxFullTextWindowCharacters: maxFullTextWindowCharacters
        )

        return FocusSnapshotTextCapture(
            textLength: effectiveLength,
            textBeforeCursor: rangedPrefix ?? fullText.flatMap { prefix(of: $0, selectedRange: validSelection) },
            textAfterCursor: FocusSnapshotTextWindow.limitedPrefix(
                rangedSuffix,
                maxCharacters: maxTextAfterCursorCharacters
            ) ?? fallbackWindow.textAfterCursor,
            selectedText: FocusSnapshotTextWindow.limitedPrefix(
                rangedSelection,
                maxCharacters: maxSelectedTextCharacters
            ) ?? fallbackWindow.selectedText,
            fullTextWindow: FocusSnapshotTextWindow.limitedPrefix(
                rangedWindow,
                maxCharacters: maxFullTextWindowCharacters
            ) ?? fallbackWindow.fullTextWindow
        )
    }

    private static func textWindowRange(
        textLength: Int,
        selectedRange: NSRange?,
        maxCharacters: Int
    ) -> CFRange? {
        guard textLength > 0, maxCharacters > 0 else { return nil }
        let length = min(textLength, maxCharacters)
        let rawAnchor = selectedRange.map { $0.location + ($0.length / 2) } ?? textLength
        let anchor = min(max(0, rawAnchor), textLength)
        let preferredStart = max(0, anchor - (length / 2))
        let start = min(preferredStart, max(0, textLength - length))
        return CFRange(location: start, length: length)
    }

    private static func prefix(of fullText: String, selectedRange: NSRange?) -> String? {
        guard let selectedRange else { return fullText }
        let length = (fullText as NSString).length
        guard selectedRange.location <= length else { return fullText }
        return UTF16TextRange.prefix(fullText, endingAt: selectedRange.location)
    }

    private static func suffix(of fullText: String, selectedRange: NSRange?) -> String? {
        guard let selectedRange else { return nil }
        let start = selectedRange.location + selectedRange.length
        guard start <= (fullText as NSString).length else { return nil }
        return UTF16TextRange.suffix(fullText, startingAt: start)
    }

    private static func selection(in fullText: String, selectedRange: NSRange?) -> String? {
        guard let selectedRange, selectedRange.length > 0 else { return nil }
        return UTF16TextRange.substring(fullText, enclosedBy: selectedRange)
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
        let activeDomainResolution = browserResolver.activeDomainResolution(for: bundleID)
        let activeDomain = activeDomainResolution.domain
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
        let textCapture = FocusSnapshotTextCapture.resolve(
            selectedRange: selectedRange,
            textLength: axHelper.numberOfCharacters(from: focusedElement),
            readRange: { range in
                axHelper.stringForRange(from: focusedElement, range: range)
            },
            readFullText: {
                axHelper.readableText(from: focusedElement)
            }
        )
        guard !Self.isMaskedSecureText(textCapture) else {
            throw AXTextContextError.secureOrUnsupportedField
        }

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
            domainResolution: activeDomainResolution.resolvingEffectiveDomain(domain),
            role: role,
            subrole: subrole,
            isGoogleDocsElement: isGoogleDocsElement,
            isCodexComposerElement: isCodexComposerElement,
            selectedRange: selectedRange,
            textLength: textCapture.textLength,
            textBeforeCursor: textCapture.textBeforeCursor,
            textAfterCursor: textCapture.textAfterCursor,
            selectedText: textCapture.selectedText,
            fullTextWindow: textCapture.fullTextWindow
        )
    }

    private static func isMaskedSecureText(_ capture: FocusSnapshotTextCapture) -> Bool {
        guard capture.textLength <= 128 else { return false }
        let value = [capture.textBeforeCursor, capture.selectedText, capture.textAfterCursor]
            .compactMap { $0 }
            .joined()
        return SecureFieldClassifier.isSecure(SecureFieldMetadata(value: value))
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
        if let numberOfCharacters = axHelper.numberOfCharacters(from: element),
           numberOfCharacters >= 0 {
            return true
        }
        if axHelper.selectedRange(from: element) != nil {
            return true
        }
        return axHelper.readableText(from: element) != nil
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
