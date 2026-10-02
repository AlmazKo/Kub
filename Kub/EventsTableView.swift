import AppKit

/// Native, sortable table of a single resource's Events (detail "Events" tab) —
/// replaces the plain `kubectl get events` text with columns (Time / Type /
/// Reason / Message / Count), newest first, Type coloured by severity.
final class EventsTableView: NSView {
    private let table = SpeedSearchTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = TableMessageLabel()
    private let cellCopy = CellCopyMenu()
    private var unfiltered: [ResourceRow] = []
    private var events: [ResourceRow] = []   // filtered + sorted (what's shown)
    private var filter = ""
    private var sortColumn = "age"
    private var sortAscending = true   // age ascending = smallest age = newest first

    private struct Col { let id, title: String; let width, minW: CGFloat; let mono: Bool }
    private static let cols: [Col] = [
        Col(id: "age", title: "Time", width: 96, minW: 72, mono: true),
        Col(id: "type", title: "Type", width: 80, minW: 60, mono: false),
        Col(id: "reason", title: "Reason", width: 170, minW: 100, mono: false),
        Col(id: "message", title: "Message", width: 420, minW: 160, mono: false),
        Col(id: "count", title: "Count", width: 56, minW: 46, mono: true),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for c in Self.cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.minW
            if c.mono { col.headerCell.alignment = .right }
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            table.addTableColumn(col)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 18
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing   // keep content-fit widths
        table.gridStyleMask = []
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [NSSortDescriptor(key: "age", ascending: true)]
        cellCopy.attach(to: table)   // right-click a cell → Copy

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
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
        events = []
        table.reloadData()
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    func setEvents(_ rows: [ResourceRow]) {
        unfiltered = rows
        applyFilter()
        fitColumnsIfNeeded()
    }

    /// Row filter (from the detail pane's shared search field): any column contains it.
    func setFilter(_ query: String) {
        filter = query
        applyFilter()
    }

    private func applyFilter() {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        events = q.isEmpty ? unfiltered
            : unfiltered.filter { row in Self.cols.contains { row.value($0.id).lowercased().contains(q) } }
        sortEvents()
        table.reloadData()
        emptyLabel.stringValue = unfiltered.isEmpty ? "No recent events." : "No matching events."
        emptyLabel.isHidden = !events.isEmpty
    }

    private var fitSignature = ""
    private func fitColumnsIfNeeded() {
        let sig = "\(unfiltered.count):\(unfiltered.first?.uid ?? ""):\(unfiltered.last?.uid ?? "")"
        guard sig != fitSignature else { return }
        fitSignature = sig
        for col in table.tableColumns {
            let id = col.identifier.rawValue
            let mono = id == "age" || id == "count"
            let font: NSFont = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            let maxW: CGFloat = id == "message" ? 600 : (mono ? 96 : 240)
            col.width = ColumnFit.width(title: col.title, texts: unfiltered.map { $0.value(id) },
                                        font: font, padding: 16, minWidth: col.minWidth, maxWidth: maxW)
        }
    }

    private func sortEvents() {
        events.sort { a, b in
            let r = a.compare(to: b, column: sortColumn)
            if r != .orderedSame {
                return sortAscending ? (r == .orderedAscending) : (r == .orderedDescending)
            }
            return (a.uid ?? "").localizedCaseInsensitiveCompare(b.uid ?? "") == .orderedAscending
        }
    }
}

extension EventsTableView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortColumn = key
        sortAscending = d.ascending
        sortEvents()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < events.count else { return nil }
        let id = tableColumn.identifier.rawValue
        let ev = events[row]
        let cell = reusableCell(tableView)
        let field = cell.textField!
        let mono = id == "age" || id == "count"
        field.stringValue = ev.value(id)
        field.textColor = (id == "type") ? ev.statusKind.color : (id == "age" ? .secondaryLabelColor : .labelColor)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                          : .systemFont(ofSize: 11, weight: id == "reason" ? .semibold : .regular)
        field.alignment = mono ? .right : .natural
        field.lineBreakMode = .byTruncatingTail
        cell.toolTip = id == "message" ? ev.value("message") : nil
        return cell
    }

    private func reusableCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("EventCell")
        if let c = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return c }
        let c = NSTableCellView()
        c.identifier = id
        let f = NSTextField(labelWithString: "")
        f.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(f)
        c.textField = f
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
            f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
            f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return c
    }
}
