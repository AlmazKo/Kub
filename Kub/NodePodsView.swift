import AppKit

/// Native, sortable table of the pods scheduled on a node (node detail "Pods"
/// tab). Double-clicking a row jumps to that pod in the Pods section.
final class NodePodsView: NSView {
    private let table = SpeedSearchTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = TableMessageLabel()
    private let cellCopy = CellCopyMenu()
    private var unfiltered: [ResourceRow] = []
    private var pods: [ResourceRow] = []   // filtered + sorted (what's shown)
    private var filter = ""
    private var sortColumn = "namespace"
    private var sortAscending = true

    /// (namespace, name) of the double-clicked pod.
    var onOpenPod: ((String, String) -> Void)?

    private struct Col { let id, title: String; let width, minW: CGFloat; let mono: Bool }
    private static let cols: [Col] = [
        Col(id: "namespace", title: "Namespace", width: 150, minW: 90, mono: false),
        Col(id: "name", title: "Pod", width: 240, minW: 140, mono: false),
        Col(id: "status", title: "Status", width: 130, minW: 80, mono: false),
        Col(id: "ready", title: "Ready", width: 56, minW: 46, mono: true),
        Col(id: "restarts", title: "Restarts", width: 70, minW: 56, mono: true),
        Col(id: "age", title: "Age", width: 64, minW: 48, mono: true),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for c in Self.cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.minW
            if c.mono { col.headerCell.alignment = .right }   // numeric columns
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
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.sortDescriptors = [NSSortDescriptor(key: "namespace", ascending: true)]
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
        pods = []
        table.reloadData()
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    func setPods(_ rows: [ResourceRow]) {
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
        // Preserve selection by pod key across reloads.
        let priorKey: String? = {
            let r = table.selectedRow
            return (r >= 0 && r < pods.count) ? pods[r].key : nil
        }()
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        pods = q.isEmpty ? unfiltered
            : unfiltered.filter { row in Self.cols.contains { row.value($0.id).lowercased().contains(q) } }
        sortPods()
        table.reloadData()
        if let key = priorKey, let idx = pods.firstIndex(where: { $0.key == key }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        emptyLabel.stringValue = unfiltered.isEmpty ? "No pods scheduled on this node." : "No matching pods."
        emptyLabel.isHidden = !pods.isEmpty
    }

    /// Fit columns to content when the pod set changes (i.e. a different node) —
    /// not on every same-node refresh, which would jitter widths.
    private var fitSignature = ""
    private func fitColumnsIfNeeded() {
        let sig = "\(unfiltered.count):\(unfiltered.first?.name ?? ""):\(unfiltered.last?.name ?? "")"
        guard sig != fitSignature else { return }
        fitSignature = sig
        for col in table.tableColumns {
            let id = col.identifier.rawValue
            let mono = id == "ready" || id == "restarts" || id == "age"
            let font: NSFont = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            let maxW: CGFloat = id == "name" ? 460 : (mono ? 110 : 200)
            col.width = ColumnFit.width(title: col.title, texts: unfiltered.map { $0.value(id) },
                                        font: font, padding: 16, minWidth: col.minWidth, maxWidth: maxW)
        }
    }

    private func sortPods() {
        pods.sort { a, b in
            let r = a.compare(to: b, column: sortColumn)
            if r != .orderedSame {
                return sortAscending ? (r == .orderedAscending) : (r == .orderedDescending)
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, r < pods.count else { return }
        onOpenPod?(pods[r].namespace, pods[r].name)
    }
}

extension NodePodsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { pods.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortColumn = key
        sortAscending = d.ascending
        sortPods()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < pods.count else { return nil }
        let id = tableColumn.identifier.rawValue
        let pod = pods[row]
        let cell = reusableCell(tableView)
        let field = cell.textField!
        let mono = id == "ready" || id == "restarts" || id == "age"
        let isNS = id == "namespace"
        field.stringValue = pod.value(id)
        field.textColor = (id == "status") ? pod.statusKind.color : (isNS ? .secondaryLabelColor : .labelColor)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                          : .systemFont(ofSize: 11, weight: isNS ? .semibold : .regular)
        field.alignment = mono ? .right : .natural
        field.lineBreakMode = .byTruncatingTail
        cell.toolTip = id == "name" ? "\(pod.namespace)/\(pod.name)  —  double-click to open" : nil
        return cell
    }

    private func reusableCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("NodePodCell")
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
