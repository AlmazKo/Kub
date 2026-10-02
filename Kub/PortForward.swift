import AppKit

/// Manages live `kubectl port-forward` sessions and their UI: a small start
/// popover (local/remote ports) and a sessions list popover (status, open in
/// browser, copy, stop). Sessions are ephemeral and all torn down on window close.
@MainActor
final class PortForwardController {
    private final class Session {
        let id: Int
        let namespace: String
        let target: String          // "pod/name" for display
        let localPort: Int
        let remotePort: Int
        var status: Status
        let handle: KubectlProcess
        init(id: Int, namespace: String, target: String, localPort: Int, remotePort: Int, handle: KubectlProcess) {
            self.id = id; self.namespace = namespace; self.target = target
            self.localPort = localPort; self.remotePort = remotePort
            self.status = .connecting; self.handle = handle
        }
    }
    private enum Status { case connecting, active, failed(String) }

    private let viewModel: ClusterViewModel
    private var sessions: [Session] = []
    private var nextId = 0

    /// Fired with the active session count (for the toolbar badge).
    var onCountChanged: ((Int) -> Void)?

    private let startPopover = NSPopover()
    private let listPopover = NSPopover()
    private var pendingRow: ResourceRow?
    private var localField: NSTextField?
    private var remoteField: NSTextField?

    init(viewModel: ClusterViewModel) {
        self.viewModel = viewModel
        startPopover.behavior = .transient
        listPopover.behavior = .transient
    }

    var count: Int { sessions.count }
    static func canForward(_ kind: ResourceKind) -> Bool { kind == .pods || kind == .services }

    func stopAll() {
        sessions.forEach { $0.handle.stop() }
        sessions.removeAll()
        onCountChanged?(0)
    }

    // MARK: - Start flow

    func begin(for row: ResourceRow, anchor: NSView, rect: NSRect) {
        guard Self.canForward(row.kind), viewModel.selectedContext != nil else { return }
        pendingRow = row

        let title = NSTextField(labelWithString: "Port-forward \(row.kind.singularName) “\(row.name)”")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let local = portField("8080"), remote = portField("8080")
        localField = local; remoteField = remote
        let grid = NSGridView(views: [[caption("Local port"), local], [caption("Remote port"), remote]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6; grid.columnSpacing = 8

        let start = NSButton(title: "Start", target: self, action: #selector(confirmStart))
        start.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelStart))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, start])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        showPopover(startPopover, content: stack, width: 260, relativeTo: rect, of: anchor)
        anchor.window?.makeFirstResponder(remote)
    }

    @objc private func cancelStart() { startPopover.performClose(nil); pendingRow = nil }

    @objc private func confirmStart() {
        defer { startPopover.performClose(nil) }
        guard let row = pendingRow else { return }
        pendingRow = nil
        let local = Int(localField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let remote = Int(remoteField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        guard (1..<65536).contains(local), (1..<65536).contains(remote) else { return }
        startForward(namespace: row.namespace, resource: row.kind.kubectlResource, name: row.name,
                     display: "\(row.kind.singularName)/\(row.name)", local: local, remote: remote)
    }

    private func startForward(namespace: String, resource: String, name: String,
                              display: String, local: Int, remote: Int) {
        let id = nextId; nextId += 1
        guard let handle = viewModel.portForward(
            namespace: namespace, resource: resource, name: name, local: local, remote: remote,
            onLine: { [weak self] line in
                guard line.contains("Forwarding from") else { return }
                DispatchQueue.main.async { self?.setStatus(id, .active) }
            },
            onEnd: { [weak self] err in
                DispatchQueue.main.async { self?.ended(id, err) }
            })
        else { return }
        sessions.append(Session(id: id, namespace: namespace, target: display,
                                localPort: local, remotePort: remote, handle: handle))
        onCountChanged?(sessions.count)
        rebuildListIfShown()
    }

    private func setStatus(_ id: Int, _ status: Status) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        s.status = status
        rebuildListIfShown()
    }

    private func ended(_ id: Int, _ err: KubectlError?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }   // already removed if we stopped it
        if let err {
            sessions[idx].status = .failed(err.message)   // keep visible so the user sees why
        } else {
            sessions.remove(at: idx)
            onCountChanged?(sessions.count)
        }
        rebuildListIfShown()
    }

    // MARK: - Sessions list

    func showSessions(anchor: NSView, rect: NSRect) {
        rebuildList()
        listPopover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    private func rebuildListIfShown() { if listPopover.isShown { rebuildList() } }

    private func rebuildList() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if sessions.isEmpty {
            let empty = NSTextField(labelWithString: "No active port-forwards.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(empty)
        } else {
            sessions.forEach { stack.addArrangedSubview(sessionRow($0)) }
        }
        setPopoverContent(listPopover, content: stack, width: 340)
    }

    private func sessionRow(_ s: Session) -> NSView {
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage())
        dot.contentTintColor = statusColor(s.status)
        dot.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let title = NSTextField(labelWithString: "\(s.namespace)/\(s.target)")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = NSTextField(labelWithString: "127.0.0.1:\(s.localPort) → \(s.remotePort)  ·  \(statusText(s.status))")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let open = iconButton("safari", tip: "Open http://127.0.0.1:\(s.localPort)", action: #selector(openSession(_:)), id: s.id)
        let copy = iconButton("doc.on.doc", tip: "Copy 127.0.0.1:\(s.localPort)", action: #selector(copySession(_:)), id: s.id)
        let stop = iconButton("stop.circle.fill", tip: "Stop", action: #selector(stopSession(_:)), id: s.id)
        stop.contentTintColor = .systemRed

        let left = NSStackView(views: [dot, text])
        left.spacing = 6; left.alignment = .centerY
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [left, spacer, open, copy, stop])
        row.spacing = 4; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 316).isActive = true
        return row
    }

    @objc private func openSession(_ sender: NSButton) {
        guard let s = sessions.first(where: { $0.id == sender.tag }),
              let url = URL(string: "http://127.0.0.1:\(s.localPort)") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func copySession(_ sender: NSButton) {
        guard let s = sessions.first(where: { $0.id == sender.tag }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("127.0.0.1:\(s.localPort)", forType: .string)
    }
    @objc private func stopSession(_ sender: NSButton) {
        guard let idx = sessions.firstIndex(where: { $0.id == sender.tag }) else { return }
        sessions[idx].handle.stop()
        sessions.remove(at: idx)
        onCountChanged?(sessions.count)
        rebuildList()
    }

    // MARK: - Helpers

    private func statusColor(_ s: Status) -> NSColor {
        switch s {
        case .connecting: return .systemYellow
        case .active:     return .systemGreen
        case .failed:     return .systemRed
        }
    }
    private func statusText(_ s: Status) -> String {
        switch s {
        case .connecting:      return "connecting…"
        case .active:          return "active"
        case .failed(let m):   return "failed: \(m)"
        }
    }

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
        return l
    }
    private func portField(_ value: String) -> NSTextField {
        let f = NSTextField(string: value)
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return f
    }
    private func iconButton(_ symbol: String, tip: String, action: Selector, id: Int) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.target = self
        b.action = action
        b.tag = id
        b.toolTip = tip
        return b
    }

    private func showPopover(_ popover: NSPopover, content: NSStackView, width: CGFloat,
                             relativeTo rect: NSRect, of anchor: NSView) {
        setPopoverContent(popover, content: content, width: width)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }
    private func setPopoverContent(_ popover: NSPopover, content: NSStackView, width: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: width, height: container.fittingSize.height)
        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc
    }
}
