//
//  OverlayContentViews.swift
//  AutoComp
//
//  Overlay AppKit content views used by overlay presenters.
//

import AppKit
import AutoCompCore

private enum KeycapHintStyle {
    static func drawBackground(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }

    static func draw(rect: NSRect, text: String, font: NSFont, textColor: NSColor) {
        drawBackground(in: rect)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        attributedText.draw(
            with: rect.insetBy(dx: 2, dy: 1),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }
}

final class SimpleCaretPopupContentView: NSView {
    private let backgroundView = NSVisualEffectView()
    private let suggestionLabel = NSTextField(labelWithString: "")
    private let acceptHintKeycapView = KeycapHintView()
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 6
    private let spacing: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()

        backgroundView.frame = bounds
        let contentBounds = bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        let keycapSize = acceptHintKeycapView.intrinsicContentSize
        acceptHintKeycapView.frame = NSRect(
            x: contentBounds.maxX - keycapSize.width,
            y: bounds.minY + round((bounds.height - keycapSize.height) / 2),
            width: keycapSize.width,
            height: keycapSize.height
        )
        suggestionLabel.frame = NSRect(
            x: contentBounds.minX,
            y: contentBounds.minY,
            width: max(1, acceptHintKeycapView.frame.minX - spacing - contentBounds.minX),
            height: contentBounds.height
        )
    }

    func update(text: String, acceptKeycapHint: String, size: NSSize) {
        suggestionLabel.stringValue = text
        acceptHintKeycapView.text = acceptKeycapHint
        frame = NSRect(origin: .zero, size: size)
        needsLayout = true
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 7
        backgroundView.layer?.masksToBounds = true

        suggestionLabel.font = .systemFont(ofSize: 13)
        suggestionLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.maximumNumberOfLines = 1

        addSubview(backgroundView)
        addSubview(suggestionLabel)
        addSubview(acceptHintKeycapView)
    }
}

final class MultiSuggestionPopupContentView: NSView {
    private let backgroundView = NSVisualEffectView()
    private let rowViews = (0..<3).map { _ in MultiSuggestionPopupRowView() }
    private let padding: CGFloat = 6
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 4

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()

        backgroundView.frame = bounds
        let contentBounds = bounds.insetBy(dx: padding, dy: padding)
        for (index, rowView) in rowViews.enumerated() {
            rowView.frame = NSRect(
                x: contentBounds.minX,
                y: contentBounds.minY + CGFloat(index) * (rowHeight + rowSpacing),
                width: contentBounds.width,
                height: rowHeight
            )
        }
    }

    func update(
        alternatives: [SuggestionAlternative],
        selectedIndex: Int,
        acceptKeycapHint: String,
        previousKeycapHint: String,
        nextKeycapHint: String,
        size: NSSize
    ) {
        let visibleAlternatives = Array(alternatives.prefix(rowViews.count))
        for (index, rowView) in rowViews.enumerated() {
            guard index < visibleAlternatives.count else {
                rowView.isHidden = true
                continue
            }

            rowView.isHidden = false
            rowView.update(
                text: SimpleCaretPopupLayout.normalized(visibleAlternatives[index].visibleText),
                isSelected: index == selectedIndex,
                acceptKeycapHint: acceptKeycapHint,
                previousKeycapHint: previousKeycapHint,
                nextKeycapHint: nextKeycapHint
            )
        }
        frame = NSRect(origin: .zero, size: size)
        needsLayout = true
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 7
        backgroundView.layer?.masksToBounds = true

        addSubview(backgroundView)
        for rowView in rowViews {
            addSubview(rowView)
        }
    }
}

private final class MultiSuggestionPopupRowView: NSView {
    private let suggestionLabel = NSTextField(labelWithString: "")
    private let previousKeycapView = KeycapHintView()
    private let nextKeycapView = KeycapHintView()
    private let acceptKeycapView = KeycapHintView()
    private let horizontalPadding: CGFloat = 10
    private let spacing: CGFloat = 8
    private let keycapSpacing: CGFloat = 4
    private var isSelectedRow = false

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()

        var trailingX = bounds.maxX - horizontalPadding
        let keycapViews = [acceptKeycapView, nextKeycapView, previousKeycapView]
        for keycapView in keycapViews where !keycapView.isHidden {
            let size = keycapView.intrinsicContentSize
            trailingX -= size.width
            keycapView.frame = NSRect(
                x: trailingX,
                y: round((bounds.height - size.height) / 2),
                width: size.width,
                height: size.height
            )
            trailingX -= keycapSpacing
        }

        let labelMaxX = isSelectedRow ? trailingX - spacing : bounds.maxX - horizontalPadding
        suggestionLabel.frame = NSRect(
            x: horizontalPadding,
            y: 0,
            width: max(1, labelMaxX - horizontalPadding),
            height: bounds.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isSelectedRow else {
            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    func update(
        text: String,
        isSelected: Bool,
        acceptKeycapHint: String,
        previousKeycapHint: String,
        nextKeycapHint: String
    ) {
        suggestionLabel.stringValue = text
        isSelectedRow = isSelected
        previousKeycapView.text = previousKeycapHint
        nextKeycapView.text = nextKeycapHint
        acceptKeycapView.text = acceptKeycapHint
        previousKeycapView.isHidden = !isSelected
        nextKeycapView.isHidden = !isSelected
        acceptKeycapView.isHidden = !isSelected
        suggestionLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        needsDisplay = true
        needsLayout = true
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        suggestionLabel.font = .systemFont(ofSize: 13)
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.maximumNumberOfLines = 1

        addSubview(suggestionLabel)
        addSubview(previousKeycapView)
        addSubview(nextKeycapView)
        addSubview(acceptKeycapView)
    }
}

final class InlineGhostTextView: NSView {
    private var layout = InlineGhostTextLayout(
        panelFrame: .zero,
        lines: [],
        lineHeight: 16,
        keycapHintFrame: nil,
        placementReason: .sameLine
    )
    private var font = NSFont.systemFont(ofSize: 14)
    private var textColor = NSColor.tertiaryLabelColor
    private var textDirection = TextDirection.leftToRight
    private var acceptKeycapHint = ""

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    func update(
        layout: InlineGhostTextLayout,
        font: NSFont,
        textColor: NSColor,
        textDirection: TextDirection,
        acceptKeycapHint: String
    ) {
        self.layout = layout
        self.font = font
        self.textColor = textColor
        self.textDirection = textDirection
        self.acceptKeycapHint = acceptKeycapHint
        frame = NSRect(origin: .zero, size: layout.panelFrame.size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        switch textDirection {
        case .leftToRight:
            paragraphStyle.alignment = .left
            paragraphStyle.baseWritingDirection = .leftToRight
        case .rightToLeft:
            paragraphStyle.alignment = .right
            paragraphStyle.baseWritingDirection = .rightToLeft
        }
        for (index, line) in layout.lines.enumerated() {
            let attributedText = NSAttributedString(
                string: line.text,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
            let drawRect = NSRect(
                x: bounds.minX + line.indent,
                y: bounds.minY + CGFloat(index) * layout.lineHeight,
                width: max(1, bounds.width - line.indent),
                height: layout.lineHeight
            )
            attributedText.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if let keycapFrame = layout.keycapHintFrame {
            drawKeycap(keycapFrame.offsetBy(dx: -layout.panelFrame.minX, dy: -layout.panelFrame.minY))
        }
    }

    private func drawKeycap(_ rect: NSRect) {
        KeycapHintStyle.draw(
            rect: rect,
            text: acceptKeycapHint,
            font: NSFont.systemFont(ofSize: max(9, font.pointSize - 3), weight: .medium),
            textColor: textColor.withAlphaComponent(0.8)
        )
    }
}

final class MirrorSuggestionOverlayContentView: NSView {
    private let backgroundView = NSVisualEffectView()
    private let appLabel = NSTextField(labelWithString: "")
    private let suggestionLabel = NSTextField(labelWithString: "")
    private let acceptHintKeycapView = KeycapHintView()
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 7
    private let spacing: CGFloat = 8
    private let maxWidth: CGFloat = 420
    private let minHeight: CGFloat = 33

    var preferredSize = NSSize(width: 120, height: 33)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()

        backgroundView.frame = bounds
        let bounds = bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        var x = bounds.minX

        let appSize = appLabel.intrinsicContentSize
        appLabel.frame = NSRect(x: x, y: bounds.minY, width: min(appSize.width, 110), height: bounds.height)
        x = appLabel.frame.maxX + spacing

        let keycapSize = acceptHintKeycapView.intrinsicContentSize
        acceptHintKeycapView.frame = NSRect(
            x: bounds.maxX - keycapSize.width,
            y: bounds.minY + round((bounds.height - keycapSize.height) / 2),
            width: keycapSize.width,
            height: keycapSize.height
        )

        suggestionLabel.frame = NSRect(
            x: x,
            y: bounds.minY,
            width: max(acceptHintKeycapView.frame.minX - spacing - x, 40),
            height: bounds.height
        )
    }

    func update(text: String, appName: String, acceptKeycapHint: String) {
        appLabel.stringValue = appName
        suggestionLabel.stringValue = text
        acceptHintKeycapView.text = acceptKeycapHint

        let appWidth = min(appLabel.intrinsicContentSize.width, 110) + spacing
        let keycapWidth = acceptHintKeycapView.intrinsicContentSize.width + spacing
        let suggestionWidth = min(
            suggestionLabel.intrinsicContentSize.width,
            maxWidth - appWidth - keycapWidth - horizontalPadding * 2
        )
        let width = min(maxWidth, max(80, appWidth + suggestionWidth + keycapWidth + horizontalPadding * 2))
        preferredSize = NSSize(width: width, height: minHeight)
        frame = NSRect(origin: .zero, size: preferredSize)
        needsLayout = true
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        backgroundView.material = .popover
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true

        appLabel.font = .systemFont(ofSize: 11)
        appLabel.textColor = .secondaryLabelColor
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.maximumNumberOfLines = 1

        suggestionLabel.font = .systemFont(ofSize: 15)
        suggestionLabel.textColor = .secondaryLabelColor
        suggestionLabel.lineBreakMode = .byTruncatingTail
        suggestionLabel.maximumNumberOfLines = 1

        addSubview(backgroundView)
        addSubview(appLabel)
        addSubview(suggestionLabel)
        addSubview(acceptHintKeycapView)
    }
}

private final class KeycapHintView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 10, height: labelSize.height + 6)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 5, dy: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        KeycapHintStyle.drawBackground(in: bounds)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.85)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1

        addSubview(label)
    }
}
