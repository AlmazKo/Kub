import AppKit

/// Native table of every resource in a namespace, grouped by Kind (group-header
/// rows, like the main table's namespace grouping). Rows show Name + Age; the
/// Kind is the group header. Double-click a row to jump to that resource.
final class NamespaceInventoryView: NSView {
    private enum Row {
        case group(label: String, count: Int)
        case resource(NamespaceResource)
    }

    private let table = SpeedSearchTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = TableMessageLabel()
    private let cellCopy = CellCopyMenu()
    private var unfiltered: [NamespaceResource] = []
    private var items: [NamespaceResource] = []   // filtered (drives rows)
    private var filter = ""
    private var rows: [Row] = []
    private var namespace = ""
    private var sortKey = "name"
    private var sortAscending = true

    /// (kind, namespace, name) of the double-clicked resource.
    var onOpenResource: ((ResourceKind, String, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 320
        nameCol.minWidth = 160
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        let ageCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("age"))
        ageCol.title = "Age"
        ageCol.width = 64
        ageCol.minWidth = 48
        ageCol.headerCell.alignment = .right
        ageCol.sortDescriptorPrototype = NSSortDescriptor(key: "age", ascending: true)
        table.addTableColumn(nameCol)
        table.addTableColumn(ageCol)

        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing   // keep content-fit widths
        table.gridStyleMask = []
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        cellCopy.attach(to: table)   // right-click a cell → Copy

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.isHidden = true

        addSubview(scroll)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Speed-search: forward the internal table's type/Esc keystrokes to the detail pane.
    var onTypeSearch: ((String) -> Void)? { get { table.onTypeSearch } set { table.onTypeSearch = newValue } }
    var onEscape: (() -> Void)? { get { table.onEscape } set { table.onEscape = newValue } }
    func focusTable() { window?.makeFirstResponder(table) }

    func showLoading(_ message: String) {
        items = []
        rows = []
        table.reloadData()
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    func setItems(_ items: [NamespaceResource], namespace: String) {
        unfiltered = items
        self.namespace = namespace
        applyFilter()
        fitColumnsIfNeeded()
    }

    /// Row filter (from the detail pane's shared search field): name or kind contains it.
    func setFilter(_ query: String) {
        filter = query
        applyFilter()
    }

    private func applyFilter() {
        // Preserve the selected resource (kind + name) across a reload.
        let priorKey: String? = {
            let r = table.selectedRow
            guard r >= 0, r < rows.count, case let .resource(res) = rows[r] else { return nil }
            return "\(res.kindLabel)/\(res.name)"
        }()
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        items = q.isEmpty ? unfiltered
            : unfiltered.filter { $0.name.lowercased().contains(q) || $0.kindLabel.lowercased().contains(q) }
        rebuildRows()
        table.reloadData()
        if let key = priorKey, let idx = rows.firstIndex(where: {
            if case let .resource(res) = $0 { return "\(res.kindLabel)/\(res.name)" == key } else { return false }
        }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        emptyLabel.stringValue = unfiltered.isEmpty ? "No resources in this namespace." : "No matching resources."
        emptyLabel.isHidden = !items.isEmpty
    }

    /// Fit columns to content when the namespace's contents change — not on every refresh.
    private var fitSignature = ""
    private func fitColumnsIfNeeded() {
        let sig = "\(namespace):\(unfiltered.count)"
        guard sig != fitSignature else { return }
        fitSignature = sig
        // Name column fits resource names + group-header labels (from the full set,
        // so widths don't jump while filtering).
        var nameTexts = unfiltered.map { $0.name }
        nameTexts += Set(unfiltered.map { $0.kindLabel }).map { "\($0)  ·  0" }
        for col in table.tableColumns {
            if col.identifier.rawValue == "age" {
                col.width = ColumnFit.width(title: col.title, texts: unfiltered.map { $0.age },
                                            font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                            padding: 16, minWidth: col.minWidth, maxWidth: 110)
            } else {
                col.width = ColumnFit.width(title: col.title, texts: nameTexts,
                                            font: .systemFont(ofSize: 12), padding: 16,
                                            minWidth: col.minWidth, maxWidth: 460)
            }
        }
    }

    private func kindOrder(_ r: NamespaceResource) -> Int {
        r.kind.flatMap { ResourceKind.allCases.firstIndex(of: $0) } ?? Int.max
    }

    /// Group by Kind (logical order), each group sorted by the active column.
    private func rebuildRows() {
        let groups = Dictionary(grouping: items, by: { $0.kindLabel }).sorted { a, b in
            let oa = kindOrder(a.value[0]), ob = kindOrder(b.value[0])
            return oa != ob ? oa < ob : a.key < b.key
        }
        var built: [Row] = []
        for (label, group) in groups {
            built.append(.group(label: label, count: group.count))
            built.append(contentsOf: group.sorted(by: lessThan).map { Row.resource($0) })
        }
        rows = built
    }

    private func lessThan(_ a: NamespaceResource, _ b: NamespaceResource) -> Bool {
        let asc: Bool
        if sortKey == "age" {
            if a.ageSeconds == b.ageSeconds { return a.name < b.name }
            asc = a.ageSeconds < b.ageSeconds
        } else {
            let r = a.name.localizedCaseInsensitiveCompare(b.name)
            if r == .orderedSame { return false }
            asc = r == .orderedAscending
        }
        return sortAscending ? asc : !asc
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count, case let .resource(res) = rows[r], let kind = res.kind else { return }
        onOpenResource?(kind, namespace, res.name)
    }
}

extension NamespaceInventoryView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        sortAscending = d.ascending
        rebuildRows()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let label, let count):
            return groupCell("\(label)  ·  \(count)")
        case .resource(let res):
            guard let id = tableColumn?.identifier.rawValue else { return nil }
            if id == "age" {
                let cell = reusableLabel(tableView, id: "InvAge")
                cell.textField?.stringValue = res.age
                cell.textField?.alignment = .right
                cell.textField?.textColor = .secondaryLabelColor
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                return cell
            }
            let cell = reusableLabel(tableView, id: "InvName")
            cell.textField?.stringValue = res.name
            cell.textField?.alignment = .natural
            cell.textField?.textColor = res.kind == nil ? .secondaryLabelColor : .labelColor
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.toolTip = res.kind == nil ? res.name : "\(res.name)  —  double-click to open"
            return cell
        }
    }

    private func groupCell(_ text: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("InvGroup")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = text
        cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        return cell
    }

    private func reusableLabel(_ tableView: NSTableView, id: String) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier(id)
        if let c = tableView.makeView(withIdentifier: ident, owner: self) as? NSTableCellView { return c }
        let c = NSTableCellView()
        c.identifier = ident
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(f)
        c.textField = f
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
            f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
            f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return c
    }
}
