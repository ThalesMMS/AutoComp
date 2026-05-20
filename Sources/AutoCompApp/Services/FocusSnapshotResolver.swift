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

        let focusedElement = axHelper.resolvedFocusedElement(from: focused)
        guard !axHelper.isSecureField(focusedElement) else {
            throw AXTextContextError.secureOrUnsupportedField
        }

        let displayName = app.localizedName ?? bundleID
        let isGoogleDocsElement = isGoogleDocsEditingElement(focusedElement)
            || hasGoogleDocsDocumentAncestor(focusedElement)
        let isCodexComposerElement = isCodexComposerElement(focusedElement, bundleID: bundleID)
        let domain = resolvedDomain(bundleID: bundleID, isGoogleDocsElement: isGoogleDocsElement)
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

    private func resolvedDomain(bundleID: String, isGoogleDocsElement: Bool) -> String? {
        var domain = browserResolver.activeDomain(for: bundleID)
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
