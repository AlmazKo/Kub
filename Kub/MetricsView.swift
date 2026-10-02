import AppKit

/// Native, sortable, filterable table of a pod's Prometheus `/metrics` output.
/// A compact toolbar carries the scrape endpoint (editable port/path + reload)
/// and a filter; the table lists one row per series (metric · labels · value),
/// with the family's TYPE/HELP shown as a tooltip.
final class MetricsView: NSView {
    private let portField = NSTextField()
    private let pathField = NSTextField()
    private let loadButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let filterField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = TableMessageLabel()
    private let cellCopy = CellCopyMenu()

    private var doc = MetricsDocument()
    private var all: [MetricSample] = []
    private var shown: [MetricSample] = []
    private var query = ""
    private var sortColumn = "name"
    private var sortAscending = true

    /// Fired when the user asks to (re)load a specific endpoint (port/path override).
    var onReload: ((MetricEndpoint) -> Void)?

    private struct Col { let id, title: String; let width, minW: CGFloat; let mono: Bool }
    private static let cols: [Col] = [
        Col(id: "name", title: "Metric", width: 300, minW: 160, mono: false),
        Col(id: "labels", title: "Labels", width: 320, minW: 120, mono: false),
        Col(id: "value", title: "Value", width: 130, minW: 80, mono: true),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Toolbar: [ :port /path Load ] … count [filter]
        portField.placeholderString = "port"
        portField.alignment = .right
        portField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        portField.target = self
        portField.action = #selector(loadClicked)
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 62).isActive = true

        pathField.placeholderString = "/metrics"
        pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathField.target = self
        pathField.action = #selector(loadClicked)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        loadButton.title = "Load"
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .small
        loadButton.target = self
        loadButton.action = #selector(loadClicked)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        filterField.placeholderString = "Filter"
        filterField.controlSize = .small
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let colon = NSTextField(labelWithString: ":")
        colon.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        colon.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [colon, portField, pathField, loadButton, spacer, countLabel, filterField])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

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
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        cellCopy.attach(to: table)   // right-click a cell → Copy

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.isHidden = true

        addSubview(toolbar)
        addSubview(scroll)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - API

    func showLoading(_ message: String) {
        all = []; shown = []
        // A fetch starts fresh — don't carry the previous pod's filter across.
        query = ""; filterField.stringValue = ""
        table.reloadData()
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    func setReport(_ report: MetricsReport) {
        // Always reflect the pod currently shown (clear stale port/path if unknown).
        if let ep = report.endpoint {
            portField.stringValue = String(ep.port)
            pathField.stringValue = ep.path
        } else {
            portField.stringValue = ""
            pathField.stringValue = ""
        }
        doc = report.document
        all = report.document.samples
        applyFilter()
        // A note (discovery failed / fetch error) takes over the empty state.
        if let note = report.note, all.isEmpty {
            emptyLabel.stringValue = note
            emptyLabel.isHidden = false
        } else if all.isEmpty {
            emptyLabel.stringValue = "No metrics returned."
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
        updateCount()
    }

    // MARK: - Filtering / sorting

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(q) || $0.labels.lowercased().contains(q)
        }
        sortShown()
        table.reloadData()
        updateCount()
    }

    private func sortShown() {
        shown.sort { a, b in
            let asc: Bool
            if sortColumn == "value" {
                asc = valueLess(a.value, b.value)
                if a.value != b.value || (a.value.isNaN != b.value.isNaN) {
                    return sortAscending ? asc : !asc
                }
            } else {
                let key = sortColumn == "labels" ? \MetricSample.labels : \MetricSample.name
                let r = a[keyPath: key].localizedCaseInsensitiveCompare(b[keyPath: key])
                if r != .orderedSame { return sortAscending ? (r == .orderedAscending) : (r == .orderedDescending) }
            }
            // Stable tie-break: name, then labels.
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.labels.localizedCaseInsensitiveCompare(b.labels) == .orderedAscending
        }
    }

    /// NaN sorts last (treated as greater than any real value).
    private func valueLess(_ a: Double, _ b: Double) -> Bool {
        if a.isNaN { return false }
        if b.isNaN { return true }
        return a < b
    }

    private func updateCount() {
        countLabel.stringValue = shown.count == all.count
            ? "\(all.count) series"
            : "\(shown.count) / \(all.count) series"
    }

    @objc private func loadClicked() {
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)),
              (1..<65536).contains(port) else { return }
        let path = MetricsDiscovery.normalizePath(pathField.stringValue.trimmingCharacters(in: .whitespaces))
        pathField.stringValue = path
        onReload?(MetricEndpoint(port: port, path: path))
    }
}

extension MetricsView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === filterField else { return }
        query = filterField.stringValue
        applyFilter()
    }
}

extension MetricsView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortColumn = key
        sortAscending = d.ascending
        sortShown()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < shown.count else { return nil }
        let id = tableColumn.identifier.rawValue
        let sample = shown[row]
        let cell = reusableCell(tableView)
        let field = cell.textField!
        switch id {
        case "value":
            field.stringValue = sample.valueText
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            field.textColor = .labelColor
            cell.toolTip = nil
        case "labels":
            field.stringValue = sample.labels
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .natural
            field.textColor = .secondaryLabelColor
            cell.toolTip = sample.labels.isEmpty ? nil : sample.labels
        default:   // name
            field.stringValue = sample.name
            field.font = .systemFont(ofSize: 11, weight: .regular)
            field.alignment = .natural
            field.textColor = .labelColor
            cell.toolTip = tooltip(for: sample.name)
        }
        field.lineBreakMode = .byTruncatingTail
        return cell
    }

    /// TYPE + HELP for the metric family, shown on hover over the name cell.
    private func tooltip(for name: String) -> String? {
        let type = doc.type[name]
        let help = doc.help[name]
        switch (type, help) {
        case let (t?, h?): return "\(name) (\(t))\n\(h)"
        case let (t?, nil): return "\(name) (\(t))"
        case let (nil, h?): return "\(name)\n\(h)"
        default: return nil
        }
    }

    private func reusableCell(_ tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("MetricCell")
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
