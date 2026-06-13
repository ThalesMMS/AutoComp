import AppKit
import SwiftUI

@MainActor
protocol PermissionOverlayPresenting: AnyObject {
    func show(flow: PermissionGuidanceFlow, anchorFrame: CGRect?)
    func close()
}

@MainActor
final class PermissionOverlayWindowController: PermissionOverlayPresenting {
    private var panel: PermissionOverlayPanel?
    private let onCancel: () -> Void
    private let screenFrameProvider: @MainActor (CGRect?) -> CGRect

    init(
        onCancel: @escaping () -> Void,
        screenFrameProvider: @escaping @MainActor (CGRect?) -> CGRect = {
            PermissionOverlayWindowController.visibleScreenFrame(containing: $0)
        }
    ) {
        self.onCancel = onCancel
        self.screenFrameProvider = screenFrameProvider
    }

    func show(flow: PermissionGuidanceFlow, anchorFrame: CGRect?) {
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(rootView: PermissionOverlayContentView(
            flow: flow,
            onCancel: onCancel
        ))
        panel.contentView = hostingView
        let fittingHeight = max(176, ceil(hostingView.fittingSize.height))
        panel.setContentSize(NSSize(width: 360, height: fittingHeight))
        panel.setFrame(frame(for: panel, anchorFrame: anchorFrame), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }

    private func makePanel() -> PermissionOverlayPanel {
        let panel = PermissionOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 176),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }

    private func frame(for panel: NSPanel, anchorFrame: CGRect?) -> NSRect {
        Self.frame(
            size: panel.frame.size,
            anchorFrame: anchorFrame,
            screenFrame: screenFrameProvider(anchorFrame)
        )
    }

    static func frame(size: CGSize, anchorFrame: CGRect?, screenFrame: CGRect) -> NSRect {
        let origin: CGPoint

        if let anchorFrame {
            let x = min(max(anchorFrame.maxX - size.width - 24, screenFrame.minX + 16), screenFrame.maxX - size.width - 16)
            let y = min(max(anchorFrame.maxY - size.height - 88, screenFrame.minY + 16), screenFrame.maxY - size.height - 16)
            origin = CGPoint(x: x, y: y)
        } else {
            origin = CGPoint(
                x: screenFrame.maxX - size.width - 24,
                y: screenFrame.maxY - size.height - 72
            )
        }

        return NSRect(origin: origin, size: size)
    }

    private static func visibleScreenFrame(containing anchorFrame: CGRect?) -> CGRect {
        if let anchorFrame,
           let screen = NSScreen.screens.first(where: { screen in
               screen.frame.intersects(anchorFrame)
                   || screen.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.midY))
           }) {
            return screen.visibleFrame
        }

        return NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

private final class PermissionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PermissionOverlayContentView: View {
    let flow: PermissionGuidanceFlow
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: flow.kind.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(flow.kind.title)
                        .font(.headline)
                    Text(flow.kind.guidanceActionTitle)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            PermissionDragSourceView(hostApp: flow.hostApp)
                .frame(height: 44)

            Text(flow.fallbackText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }
}

struct PermissionDragSourceView: NSViewRepresentable {
    let hostApp: PermissionHostApp

    func makeNSView(context: Context) -> PermissionDragSourceAppKitView {
        PermissionDragSourceAppKitView(hostApp: hostApp)
    }

    func updateNSView(_ nsView: PermissionDragSourceAppKitView, context: Context) {
        nsView.update(hostApp: hostApp)
    }
}

final class PermissionDragSourceAppKitView: NSView, NSDraggingSource {
    private var hostApp: PermissionHostApp
    private let rowView = NSView()
    private let iconChrome = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()

    init(hostApp: PermissionHostApp) {
        self.hostApp = hostApp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        update(hostApp: hostApp)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 44)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let permissionTargetURL = hostApp.permissionTargetURL else {
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: permissionTargetURL as NSURL)
        draggingItem.setDraggingFrame(draggingFrame(), contents: draggingImage())

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        rowView.isHidden = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        rowView.isHidden = false
    }

    func update(hostApp: PermissionHostApp) {
        self.hostApp = hostApp
        titleLabel.stringValue = hostApp.displayName
        detailLabel.stringValue = hostApp.identityDetail
        rowView.alphaValue = hostApp.permissionTargetURL == nil ? 0.65 : 1

        if let permissionTargetURL = hostApp.permissionTargetURL {
            iconView.image = NSWorkspace.shared.icon(forFile: permissionTargetURL.path)
            statusIconView.image = NSImage(
                systemSymbolName: "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: nil
            )
        } else {
            iconView.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
            statusIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
    }

    private func setup() {
        wantsLayer = true

        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 8
        rowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowView)

        iconChrome.wantsLayer = true
        iconChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        iconChrome.layer?.cornerRadius = 6
        iconChrome.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(iconChrome)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconChrome.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(detailLabel)

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        statusIconView.contentTintColor = .tertiaryLabelColor
        rowView.addSubview(statusIconView)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 44),

            iconChrome.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 8),
            iconChrome.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            iconChrome.widthAnchor.constraint(equalToConstant: 26),
            iconChrome.heightAnchor.constraint(equalToConstant: 26),

            iconView.centerXAnchor.constraint(equalTo: iconChrome.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconChrome.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusIconView.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 7),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusIconView.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            statusIconView.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10),
            statusIconView.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            statusIconView.widthAnchor.constraint(equalToConstant: 14),
            statusIconView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.78).cgColor
        }
    }

    private func draggingFrame() -> NSRect {
        convert(rowView.bounds, from: rowView)
    }

    private func draggingImage() -> NSImage {
        let image = NSImage(size: rowView.bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current {
            rowView.displayIgnoringOpacity(rowView.bounds, in: context)
        }
        image.unlockFocus()
        return image
    }
}
