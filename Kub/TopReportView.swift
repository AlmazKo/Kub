import AppKit

/// Renders a `PodTopReport` as an indicator panel (`TopSummaryView`) above a
/// sortable, monospaced process table. Swapped in for the plain text view when
/// the Top detail tab is shown.
final class TopReportView: NSView {
    private let summary = TopSummaryView()
    private let table = ActionTableView()
    private let scroll = NSScrollView()

    private var columns: [String] = []
    private var rows: [[String]] = []
    private var sortColumn: Int?
    private var sortAscending = false
    private var numericColumns: Set<Int> = []   // right-aligned (PID, %CPU, VSZ, …)

    /// Heap dump / profile requested from a process row's context menu.
    var onProcessAction: ((ProcessAction) -> Void)?
    private var menuPID: String?
    private var menuCommand = ""
    private var podNamespace = ""
    private var podName = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.setContentHuggingPriority(.required, for: .vertical)
        summary.setContentCompressionResistancePriority(.required, for: .vertical)

        table.menuProvider = { [weak self] row, col in self?.processMenu(row, column: col) }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing   // keep content-fit widths
        table.allowsMultipleSelection = false
        table.rowHeight = 18
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(summary)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: topAnchor),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - API

    func showLoading(_ message: String) {
        summary.showLoading(message)
        rows = []
        table.reloadData()
    }

    func update(_ report: PodTopReport) {
        summary.update(report)
        let podChanged = report.podNamespace != podNamespace || report.podName != podName
        podNamespace = report.podNamespace
        podName = report.podName

        // Preserve the selected process across the 3s refresh, keyed by the PID
        // column (NOT column 0 — that's USER/UID for the ps fallbacks). Falls back
        // to the whole row when there's no PID column (e.g. single-column output).
        func rowKey(_ row: [String]) -> String {
            if let c = pidColumn, c < row.count { return row[c] }
            return row.joined(separator: "\u{1f}")
        }
        let priorKey: String? = {
            let r = table.selectedRow
            guard r >= 0, r < rows.count, !rows[r].isEmpty else { return nil }
            return rowKey(rows[r])
        }()

        let columnsChanged = report.processColumns != columns
        if columnsChanged {
            columns = report.processColumns
            sortColumn = nil
            rebuildColumns()
        }
        rows = report.processes
        recomputeNumericColumns()
        sortRows()
        table.reloadData()
        if columnsChanged || podChanged { fitColumnsToContent() }   // fit on open/pod switch, not every poll

        if let key = priorKey,
           let idx = rows.firstIndex(where: { !$0.isEmpty && rowKey($0) == key }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    /// Fit columns to the widest process value (+ header). COMMAND is free text,
    /// so it gets a higher cap. All Top cells use the monospaced font.
    private func fitColumnsToContent() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for (i, col) in table.tableColumns.enumerated() {
            let isCommand = i == columns.count - 1
            let texts = rows.map { i < $0.count ? $0[i] : "" }
            col.width = ColumnFit.width(title: col.title, texts: texts, font: font,
                                        padding: 14, minWidth: col.minWidth, maxWidth: isCommand ? 600 : 260)
        }
    }

    /// A column is numeric (→ right-aligned) when all its non-empty cells parse.
    private func recomputeNumericColumns() {
        numericColumns = []
        for c in 0..<columns.count {
            let isLast = c == columns.count - 1   // COMMAND is free text — never numeric
            let values = rows.compactMap { c < $0.count ? $0[c] : nil }.filter { !$0.isEmpty && $0 != "-" }
            if !isLast, !values.isEmpty, values.allSatisfy({ Self.numeric($0) != nil }) {
                numericColumns.insert(c)
            }
        }
        for (i, col) in table.tableColumns.enumerated() {
            col.headerCell.alignment = numericColumns.contains(i) ? .right : .natural
        }
    }

    // MARK: - Columns / sorting

    private func rebuildColumns() {
        for col in table.tableColumns { table.removeTableColumn(col) }
        // Removing columns doesn't clear sortDescriptors, which would leave a
        // stale sort arrow on a column that no longer exists — reset it.
        table.sortDescriptors = []
        for (i, name) in columns.enumerated() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(i)"))
            col.title = name
            let isCommand = (i == columns.count - 1)
            col.width = isCommand ? 560 : 74
            col.minWidth = isCommand ? 200 : 40
            col.maxWidth = isCommand ? 4000 : 260
            col.sortDescriptorPrototype = NSSortDescriptor(key: "col\(i)", ascending: true)
            table.addTableColumn(col)
        }
    }

    private func sortRows() {
        guard let c = sortColumn else { return }
        rows.sort { a, b in
            let av = c < a.count ? a[c] : ""
            let bv = c < b.count ? b[c] : ""
            let ascending: Bool
            if let an = Self.numeric(av), let bn = Self.numeric(bv) {
                if an == bn { return false }
                ascending = an < bn
            } else {
                let r = av.localizedCaseInsensitiveCompare(bv)
                if r == .orderedSame { return false }
                ascending = (r == .orderedAscending)
            }
            return sortAscending ? ascending : !ascending
        }
    }

    /// Best-effort numeric value for sorting. Handles clock durations
    /// ("10:05", "1:23.45" TIME+, "01:23:45"), percentages, binary `i`, and
    /// k/m/g/t scale suffixes. nil for non-numeric cells (STAT, COMMAND) → those
    /// fall back to string compare.
    static func numeric(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }

        // Sexagesimal clock duration (M:SS, M:SS.cc, HH:MM:SS) → seconds.
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 2 {
                var total = 0.0
                for part in parts {
                    guard let v = Double(part) else { return nil }
                    total = total * 60 + v
                }
                return total
            }
        }

        var s = trimmed
        if s.hasSuffix("%") { s.removeLast() }
        if let last = s.last, last == "i" || last == "I" { s.removeLast() }
        var mult = 1.0
        if let last = s.last, last.isLetter {
            switch Character(last.lowercased()) {
            case "k": mult = 1e3
            case "m": mult = 1e6
            case "g": mult = 1e9
            case "t": mult = 1e12
            default: return nil
            }
            s.removeLast()
        }
        guard let v = Double(s) else { return nil }
        return v * mult
    }

    // MARK: - Process context menu (heap dump / profile)

    private var pidColumn: Int? { columns.firstIndex { $0.uppercased() == "PID" } }

    private func processMenu(_ row: Int, column: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else { return nil }
        let menu = NSMenu()

        // Copy the exact clicked cell ("Copy <Column>") — independent of JDK.
        if let item = CellCopy.menuItem(table, row: row, column: column) {
            menu.addItem(item)
        }

        // JVM diagnostics under a "JDK" submenu — only for a real PID row and when
        // the JDK integration (Settings) is on.
        if onProcessAction != nil, !podName.isEmpty, let pidCol = pidColumn,
           pidCol < rows[row].count, Int(rows[row][pidCol]) != nil,
           Settings.jdkIntegrationEnabled {
            menuPID = rows[row][pidCol]
            menuCommand = rows[row].last ?? ""
            if !menu.items.isEmpty { menu.addItem(.separator()) }

            let jdk = NSMenuItem(title: "JDK", action: nil, keyEquivalent: "")
            let jdkMenu = NSMenu()
            let dump = NSMenuItem(title: "Heap Dump…", action: #selector(dumpClicked), keyEquivalent: "")
            dump.target = self
            jdkMenu.addItem(dump)

            let profile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, preset) in AsyncProfile.allCases.enumerated() {
                let item = NSMenuItem(title: "\(preset.menuTitle)…", action: #selector(profileClicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                sub.addItem(item)
            }
            profile.submenu = sub
            jdkMenu.addItem(profile)
            jdk.submenu = jdkMenu
            menu.addItem(jdk)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func dumpClicked() {
        guard let pid = menuPID, !podName.isEmpty else { return }
        onProcessAction?(ProcessAction(kind: .heapDump, pid: pid, command: menuCommand,
                                       namespace: podNamespace, podName: podName))
    }

    @objc private func profileClicked(_ sender: NSMenuItem) {
        guard let pid = menuPID, !podName.isEmpty,
              sender.tag >= 0, sender.tag < AsyncProfile.allCases.count else { return }
        onProcessAction?(ProcessAction(kind: .profile(AsyncProfile.allCases[sender.tag]), pid: pid,
                                       command: menuCommand, namespace: podNamespace, podName: podName))
    }
}

extension TopReportView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let idx = Int(tableColumn.identifier.rawValue.dropFirst(3)) else { return nil }
        let id = NSUserInterfaceItemIdentifier("TopCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let value = (row < rows.count && idx < rows[row].count) ? rows[row][idx] : ""
        cell.textField?.stringValue = value
        cell.textField?.alignment = numericColumns.contains(idx) ? .right : .natural
        cell.toolTip = value.isEmpty ? nil : value
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let k = d.key, k.hasPrefix("col"),
              let idx = Int(k.dropFirst(3)) else { return }
        sortColumn = idx
        sortAscending = d.ascending
        sortRows()
        tableView.reloadData()
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
