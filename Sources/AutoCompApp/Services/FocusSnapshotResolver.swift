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
    let isGoogleDocsElement: Bool
    let isCodexComposerElement: Bool
    let selectedRange: NSRange?
    let fullText: String?
    let textLength: Int
    let textBeforeCursor: String?
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
            isGoogleDocsElement: isGoogleDocsElement,
            isCodexComposerElement: isCodexComposerElement,
            selectedRange: selectedRange,
            fullText: fullText,
            textLength: textLength,
            textBeforeCursor: textBeforeCursor
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
