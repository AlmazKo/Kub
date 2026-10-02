import AppKit

/// Left navigation: a flat, native source list of resource kinds (with element
/// counts): enabled kinds, one thin divider, then the hidden kinds — no headers,
/// no collapsing.
/// Kinds can be hidden (right-click): hidden kinds render dimmed/compact and are
/// never queried.
final class SidebarViewController: NSViewController {
    private enum Item {
        case kind(ResourceKind)
        case separator
    }

    private let table = ActionTableView()
    private let scroll = NSScrollView()
    /// Enabled kinds, a divider, then the disabled kinds at the bottom.
    private var items: [Item] = []
    private var currentKind: ResourceKind?
    private var counts: [ResourceKind: Int] = [:]
    private var eventsUnread = 0
    private var isUpdatingSelection = false

    private static let dragType = NSPasteboard.PasteboardType("com.kub.sidebar.kind")

    private func rebuildItems() {
        var result: [Item] = []
        let order = ResourceKindStore.order
        let enabled = order.filter { ResourceKindStore.isEnabled($0) }
        let disabled = order.filter { !ResourceKindStore.isEnabled($0) }
        result.append(contentsOf: enabled.map { Item.kind($0) })
        if !enabled.isEmpty, !disabled.isEmpty { result.append(.separator) }
        result.append(contentsOf: disabled.map { Item.kind($0) })
        items = result
    }

    var onSelectKind: ((ResourceKind) -> Void)?
    /// Fired when a kind is shown/hidden via the context menu.
    var onToggleKind: ((ResourceKind, Bool) -> Void)?

    override func loadView() {
        rebuildItems()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        table.allowsEmptySelection = false
        table.menuProvider = { [weak self] row, _ in self?.kindMenu(row) }
        table.registerForDraggedTypes([Self.dragType])   // drag-to-reorder
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        view = scroll
    }

    /// Rebuild after the enabled/disabled set changed externally (e.g. navigating
    /// to a hidden kind from a namespace inventory).
    func reloadKinds() {
        rebuildAndReload()
    }

    /// Rebuild + reload, preserving the current kind selection. The reload is
    /// wrapped in `isUpdatingSelection` so the auto-select AppKit fires during
    /// reloadData (allowsEmptySelection is off) can't navigate to row 0.
    private func rebuildAndReload() {
        rebuildItems()
        isUpdatingSelection = true
        table.reloadData()
        isUpdatingSelection = false
        if let current = currentKind { setSelectedKind(current) }
    }

    func setCounts(_ counts: [ResourceKind: Int]) {
        self.counts = counts
        for row in 0..<items.count {
            if case let .kind(kind) = items[row],
               let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarKindCell {
                cell.setBadge(badge(for: kind))
            }
        }
    }

    /// Set the unread-events count and refresh the Events row's badge.
    func setEventsUnread(_ count: Int) {
        eventsUnread = count
        refreshBadge(for: .events)
    }

    /// Trailing badge for a kind: element count, except Events shows its unread
    /// count as "+N" (or "0" when there are none) — hidden while Events is current.
    private func badge(for kind: ResourceKind) -> String? {
        guard ResourceKindStore.isEnabled(kind) else { return nil }
        if kind == .events {
            if currentKind == .events { return nil }
            return eventsUnread > 0 ? "+\(eventsUnread)" : "0"
        }
        return counts[kind].map(String.init)
    }

    private func refreshBadge(for kind: ResourceKind) {
        guard let row = items.firstIndex(where: { if case .kind(kind) = $0 { return true } else { return false } }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarKindCell else { return }
        cell.setBadge(badge(for: kind))
    }

    func setSelectedKind(_ kind: ResourceKind) {
        let previous = currentKind
        currentKind = kind
        if previous == .events || kind == .events { refreshBadge(for: .events) }   // active state changed
        guard let row = items.firstIndex(where: { if case .kind(kind) = $0 { return true } else { return false } })
        else { return }
        isUpdatingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isUpdatingSelection = false
    }

    private func kind(at row: Int) -> ResourceKind? {
        guard row >= 0, row < items.count, case let .kind(k) = items[row] else { return nil }
        return k
    }

    // MARK: - Show/hide

    private func kindMenu(_ row: Int) -> NSMenu? {
        guard let kind = kind(at: row) else { return nil }
        let menu = NSMenu()
        let enabled = ResourceKindStore.isEnabled(kind)
        let item = NSMenuItem(title: enabled ? "Hide \(kind.displayName)" : "Show \(kind.displayName)",
                              action: #selector(toggleKind(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = kind
        menu.addItem(item)
        return menu
    }

    @objc private func toggleKind(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? ResourceKind else { return }
        let nowEnabled = !ResourceKindStore.isEnabled(kind)
        ResourceKindStore.setEnabled(kind, nowEnabled)
        rebuildAndReload()
        onToggleKind?(kind, nowEnabled)
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - Drag to reorder (and drag across the divider to show/hide)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case let .kind(kind) = items[row] else { return nil }   // separator isn't draggable
        let item = NSPasteboardItem()
        item.setString(kind.rawValue, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above,
              info.draggingPasteboard.availableType(from: [Self.dragType]) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let dragged = ResourceKind(rawValue: raw),
              let from = items.firstIndex(where: { if case .kind(dragged) = $0 { return true } else { return false } })
        else { return false }

        var arrangement = items
        let moved = arrangement.remove(at: from)
        let insertAt = min(from < row ? row - 1 : row, arrangement.count)
        arrangement.insert(moved, at: insertAt)
        applyArrangement(arrangement)
        return true
    }

    /// Persist the new order and reconcile enabled/disabled from the divider position
    /// (kinds above the separator are enabled, below are disabled).
    private func applyArrangement(_ arrangement: [Item]) {
        // The only separator is the enabled/disabled divider.
        let separator = arrangement.firstIndex { if case .separator = $0 { return true } else { return false } }
        var enabledKinds: [ResourceKind] = []
        var disabledKinds: [ResourceKind] = []
        for (i, item) in arrangement.enumerated() {
            guard case let .kind(k) = item else { continue }
            if let separator, i > separator { disabledKinds.append(k) } else { enabledKinds.append(k) }
        }
        var changed: [(ResourceKind, Bool)] = []
        for k in enabledKinds where !ResourceKindStore.isEnabled(k) { changed.append((k, true)) }
        for k in disabledKinds where ResourceKindStore.isEnabled(k) { changed.append((k, false)) }

        ResourceKindStore.setOrder(enabledKinds + disabledKinds)
        for (k, enabled) in changed { ResourceKindStore.setEnabled(k, enabled) }

        rebuildAndReload()
        for (k, enabled) in changed { onToggleKind?(k, enabled) }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .separator: return 13
        case .kind(let kind): return ResourceKindStore.isEnabled(kind) ? 30 : 22
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch items[row] {
        case .kind(let kind): return ResourceKindStore.isEnabled(kind)
        case .separator: return false
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .separator:
            return separatorCell()
        case .kind(let kind):
            let id = NSUserInterfaceItemIdentifier("SidebarKindCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarKindCell) ?? {
                let c = SidebarKindCell()
                c.identifier = id
                return c
            }()
            cell.configure(symbol: kind.symbol, title: kind.displayName,
                           badge: badge(for: kind), enabled: ResourceKindStore.isEnabled(kind))
            return cell
        }
    }

    private func separatorCell() -> NSView {
        let id = NSUserInterfaceItemIdentifier("SidebarSeparator")
        if let cell = table.makeView(withIdentifier: id, owner: self) { return cell }
        let container = NSView()
        container.identifier = id
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection, table.selectedRow >= 0, table.selectedRow < items.count else { return }
        switch items[table.selectedRow] {
        case .kind(let kind): onSelectKind?(kind)
        case .separator: break
        }
    }
}

/// Sidebar row: icon + title + trailing count. Dimmed/compact when disabled.
final class SidebarKindCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(title)
        addSubview(count)
        self.imageView = icon
        self.textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(symbol: String, title: String, badge: String?, enabled: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = enabled ? .controlAccentColor : .tertiaryLabelColor
        self.title.stringValue = title
        self.title.textColor = enabled ? .labelColor : .tertiaryLabelColor
        self.title.font = .systemFont(ofSize: enabled ? 13 : 12)
        setBadge(enabled ? badge : nil)
    }

    /// Trailing badge: element count, or the events "+N" unread — same plain style.
    func setBadge(_ text: String?) {
        count.stringValue = text ?? ""
    }
}
