import AppKit

/// Table that exposes a per-row contextual menu on right-click. Inherits IDEA-style
/// speed-search from SpeedSearchTableView (active only where `onTypeSearch` is set —
/// the main table routes to the toolbar filter; the sidebar keeps type-select).
final class ActionTableView: SpeedSearchTableView {
    var menuProvider: ((Int, Int) -> NSMenu?)?   // (row, clicked column)

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row, self.column(at: point))
    }
}

/// Main cluster view: one sortable table of the selected `ResourceKind` across
/// all namespaces. Grouping by namespace is an option; search and "hide system
/// namespaces" filter the rows; each row carries a mini action button; a bottom
/// bar shows the currently running kubectl command.
final class ResourceListViewController: NSViewController {
    private enum Item {
        case group(String)
        case row(ResourceRow)
    }

    private let table = ActionTableView()
    private var emptyLabel: TableMessageLabel!
    private var lastError: String?
    private var statusLabel: NSTextField!
    private var statusSpinner: NSProgressIndicator!
    private var contextBand: NSView!
    private var contextBandHeight: NSLayoutConstraint!

    private let actionsColumnId = "actions"
    /// Set when a kind's columns are first shown and have never been content-fit;
    /// the next non-empty data load fits them once, then autosave owns widths.
    private var pendingFit = false

    private var kind: ResourceKind = .pods
    private var groupingOn = true                         // global on/off (persisted)
    private var preferredGroupBy: GroupBy = .namespace    // preferred dimension (persisted)
    private var groupBy: GroupBy?                          // resolved for the current kind (nil = flat)
    private var collapsedGroups: Set<String> = []         // collapsed group keys (session; cleared on kind/dim change)
    private let groupingOnKey = "GroupingEnabledV1"
    private let groupDimKey = "GroupByDimensionV1"
    /// The header text a row falls under (empty when flat).
    private func groupKey(_ row: ResourceRow) -> String { groupBy?.key(for: row) ?? "" }

    /// Grouping state for the toolbar's Group menu.
    var availableGroupings: [GroupBy] { kind.groupings }
    var currentGrouping: GroupBy? { groupBy }

    /// Set grouping to a dimension (nil = flat/off) from the toolbar menu.
    func setGroupBy(_ dim: GroupBy?) {
        if let dim { preferredGroupBy = dim; groupingOn = true } else { groupingOn = false }
        resolveGroupBy()
        commitGrouping()
    }


    /// Derive the actual grouping for the current kind from the global on/off +
    /// preferred dimension: use the preference if the kind supports it, else its
    /// default, else the first available (nil → flat, e.g. events/nodes when off).
    private func resolveGroupBy() {
        guard groupingOn else { groupBy = nil; return }
        let opts = kind.groupings
        if opts.contains(preferredGroupBy) { groupBy = preferredGroupBy }
        else if let d = kind.defaultGrouping, opts.contains(d) { groupBy = d }
        else { groupBy = opts.first }
    }
    private var sortColumn: String?
    private var sortAscending = true

    private var allRows: [ResourceRow] = []
    private var rows: [ResourceRow] = []
    private var items: [Item] = []
    private var query = ""
    private var hideSystem = false
    private var pinnedOnly = false                    // bookmark toolbar toggle
    private var pinnedNamespaces: Set<String> = []    // current context's pinned namespaces
    private var isLoading = false
    private var loadingMessage: String?

    private let tableScroll = NSScrollView()
    private let detailSplit = NSSplitView()
    private let detailPane = DetailPaneView()
    private var detailVisible = false
    private var pendingDetailPosition = false
    private var savedDetailPosition: CGFloat?   // remembers the user's dragged height
    private var lastDetailKey: String?          // de-dups detail reloads across polls

    var onPrimaryAction: ((ResourceRow) -> Void)?
    /// Fired when a scalable workload's "Scale…" item is chosen.
    var onScaleAction: ((ResourceRow) -> Void)?
    var onRollbackAction: ((ResourceRow) -> Void)?
    var onTogglePin: ((ResourceRow) -> Void)?
    var isPinned: ((ResourceRow) -> Bool)?
    /// Fired by the clickable bookmark on a namespace group header (toggle its pin).
    var onTogglePinNamespace: ((String) -> Void)?
    var onPortForward: ((ResourceRow) -> Void)?
    /// Fired when the detail pane needs new content (selection / section / toggle changed).
    var onDetailReloadRequested: (() -> Void)?
    /// Fired by the error card's Reload button.
    var onReloadRequested: (() -> Void)?
    /// Fired by the "No matches" card's Clear-filter button.
    var onClearFilter: (() -> Void)?
    /// Fired by the empty card's "Show all" button to turn off the bookmark filter.
    var onClearBookmarkFilter: (() -> Void)?
    /// Speed-search on the main table → the toolbar filter field (typing / Esc).
    var onTableTypeSearch: ((String) -> Void)?
    var onTableEscape: (() -> Void)?
    func focusTable() { table.window?.makeFirstResponder(table) }
    /// Fired when a process-row diagnostic (heap dump / profile) is requested.
    var onProcessAction: ((ProcessAction) -> Void)?
    /// Fired when a pod is double-clicked in a node's Pods table (namespace, name).
    var onOpenPod: ((String, String) -> Void)?
    /// Fired when a resource is double-clicked in a namespace's inventory (kind, ns, name).
    var onOpenResource: ((ResourceKind, String, String) -> Void)?
    /// Fired when the Metrics tab requests a (re)scrape of a specific endpoint.
    var onReloadMetrics: ((MetricEndpoint) -> Void)?
    /// Pod key to select once it appears (used when jumping from a node to Pods).
    private var pendingReveal: String?
    /// True while we set the selection ourselves, so the delegate can tell a
    /// programmatic reselect from a real user click.
    private var settingSelectionProgrammatically = false

    override func loadView() {
        preferredGroupBy = GroupBy(rawValue: UserDefaults.standard.string(forKey: groupDimKey) ?? "") ?? .namespace
        groupingOn = UserDefaults.standard.object(forKey: groupingOnKey) as? Bool ?? true

        let container = NSView()

        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true   // content-fit + .noColumnAutoresizing can overflow; keep all columns reachable
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = table
        tableScroll.borderType = .noBorder

        detailSplit.translatesAutoresizingMaskIntoConstraints = false
        detailSplit.isVertical = false
        detailSplit.dividerStyle = .thin
        detailSplit.delegate = self
        detailSplit.addSubview(tableScroll)   // detail pane is added/removed on toggle
        detailPane.onSectionChanged = { [weak self] _ in self?.onDetailReloadRequested?() }
        detailPane.onReloadClicked = { [weak self] in self?.onDetailReloadRequested?() }
        detailPane.onProcessAction = { [weak self] action in self?.onProcessAction?(action) }
        detailPane.onOpenPod = { [weak self] ns, name in self?.onOpenPod?(ns, name) }
        detailPane.onOpenResource = { [weak self] kind, ns, name in self?.onOpenResource?(kind, ns, name) }
        detailPane.onReloadMetrics = { [weak self] endpoint in self?.onReloadMetrics?(endpoint) }

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 25
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.floatsGroupRows = false   // floating group rows didn't render the header's paw button
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing   // keep content-fit widths; don't stretch to fill
        table.autosaveTableColumns = true   // persist order/width/visibility per kind
        table.focusRingType = .none
        table.menuProvider = { [weak self] row, col in self?.rowMenu(row, column: col) }
        table.onTypeSearch = { [weak self] in self?.onTableTypeSearch?($0) }
        table.onEscape = { [weak self] in self?.onTableEscape?() }

        emptyLabel = TableMessageLabel()
        emptyLabel.isHidden = true

        let statusBar = makeStatusBarView()

        let band = NSView()
        band.translatesAutoresizingMaskIntoConstraints = false
        band.wantsLayer = true
        band.isHidden = true
        contextBand = band
        contextBandHeight = band.heightAnchor.constraint(equalToConstant: 0)

        container.addSubview(band)
        container.addSubview(detailSplit)
        container.addSubview(emptyLabel)
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            band.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            contextBandHeight,
            detailSplit.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailSplit.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailSplit.topAnchor.constraint(equalTo: band.bottomAnchor),
            detailSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            // Center within the table area (tableScroll), not the whole split — else
            // it drifts down over the bottom detail panel.
            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
        configure(for: kind)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if pendingDetailPosition, detailVisible, detailSplit.bounds.height > 0 {
            detailSplit.setPosition(savedDetailPosition ?? detailSplit.bounds.height * 0.55, ofDividerAt: 0)
            pendingDetailPosition = false
        }
    }

    // MARK: - Detail pane API

    func setDetailVisible(_ on: Bool) {
        if on {
            if detailPane.superview == nil { detailSplit.addSubview(detailPane) }
            detailVisible = true
            detailSplit.adjustSubviews()
            let h = detailSplit.bounds.height
            if h > 0 {
                detailSplit.setPosition(savedDetailPosition ?? h * 0.55, ofDividerAt: 0)
            } else {
                pendingDetailPosition = true
            }
            requestDetailReload(force: true)
        } else {
            // Remove the pane entirely so no divider line is left behind.
            if detailPane.superview != nil {
                if detailSplit.bounds.height > 0 { savedDetailPosition = tableScroll.frame.height }
                detailPane.removeFromSuperview()
                detailSplit.adjustSubviews()
            }
            detailVisible = false
            pendingDetailPosition = false
        }
    }

    /// Emit a detail reload only when the selection actually changed (or forced).
    /// This stops the 5s poll's programmatic reselection from re-fetching logs.
    private func requestDetailReload(force: Bool) {
        guard detailVisible else { return }
        let key = selectedRow?.key
        if !force && key == lastDetailKey { return }
        lastDetailKey = key
        onDetailReloadRequested?()
    }

    /// The context changed — `row.key` (namespace/name) is context-agnostic, so a
    /// same-named resource in the new context has the same key and the per-poll
    /// de-dup would leave the previous context's detail on screen. Force a reload.
    func contextChanged() {
        lastDetailKey = nil
        requestDetailReload(force: true)
    }

    var detailSection: DetailSection { detailPane.section }

    var selectedRow: ResourceRow? {
        let r = table.selectedRow
        guard r >= 0, r < items.count, case let .row(row) = items[r] else { return nil }
        return row
    }

    func setDetailTitle(symbol: String?, _ title: String) { detailPane.setTitle(symbol: symbol, title) }
    func setDetailText(_ text: String) { detailPane.setText(text) }
    func setDetailTopReport(_ report: PodTopReport) { detailPane.setTopReport(report) }
    func setDetailNodePods(_ pods: [ResourceRow]) { detailPane.setNodePods(pods) }
    func setDetailEvents(_ events: [ResourceRow]) { detailPane.setEvents(events) }
    func setDetailMetrics(_ report: MetricsReport) { detailPane.setMetrics(report) }
    func setDetailInventory(_ items: [NamespaceResource], namespace: String) { detailPane.setInventory(items, namespace: namespace) }
    func setDetailInventoryLoading() { detailPane.setInventoryLoading("Loading resources…") }
    func startDetailLiveLog() { detailPane.startLiveLog() }
    func appendDetailLiveLog(_ lines: [String]) { detailPane.appendLiveLog(lines) }
    func configureDetailShell(context: String, namespace: String, pod: String, isProduction: Bool) {
        detailPane.configureShell(context: context, namespace: namespace, pod: pod, isProduction: isProduction)
    }
    func stopDetailShell() { detailPane.stopShell() }

    /// Select the pod with this identity as soon as it's in the list (it may not
    /// be loaded yet right after switching to the Pods kind).
    func reveal(namespace: String, name: String) {
        pendingReveal = "\(namespace)/\(name)"
        applyPendingReveal()
    }

    private func applyPendingReveal() {
        guard let key = pendingReveal,
              let idx = items.firstIndex(where: {
                  if case let .row(r) = $0 { return r.key == key } else { return false }
              }) else { return }
        programmaticSelect(idx, scroll: true)
        pendingReveal = nil
    }

    private func programmaticSelect(_ index: Int, scroll: Bool = false) {
        settingSelectionProgrammatically = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(index) }
        settingSelectionProgrammatically = false
    }
    func setDetailLoading(_ message: String) { detailPane.setLoading(message) }
    func setDetailSections(_ sections: [DetailSection]) { detailPane.setSections(sections) }

    private func makeStatusBarView() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusSpinner = NSProgressIndicator()
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        // Don't let a long command string widen the window — truncate instead.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bar.addSubview(separator)
        bar.addSubview(statusSpinner)
        bar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 26),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            statusSpinner.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            statusSpinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 12),
            statusSpinner.heightAnchor.constraint(equalToConstant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 7),
            statusLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: - Kind / grouping / columns

    func configure(for kind: ResourceKind) {
        self.kind = kind
        collapsedGroups.removeAll()   // new kind → group keys differ
        resolveGroupBy()        // adapt grouping to what this kind supports
        rebuildColumns()
        // Apply the kind's default sort (e.g. events → newest first); nil → by name.
        if let d = kind.defaultSort {
            sortColumn = d.column
            sortAscending = d.ascending
            table.sortDescriptors = [NSSortDescriptor(key: d.column, ascending: d.ascending)]
        } else {
            sortColumn = nil
            sortAscending = true
            table.sortDescriptors = []
        }
        allRows = []
        rows = []
        items = []
        table.reloadData()
        refreshEmptyLabel()
        // Kind changed → drop any stale detail content for the previous selection.
        lastDetailKey = nil
        requestDetailReload(force: true)
    }

    // MARK: - Grouping

    /// Persist, rebuild columns for the new mode, re-filter.
    private func commitGrouping() {
        UserDefaults.standard.set(groupingOn, forKey: groupingOnKey)
        UserDefaults.standard.set(preferredGroupBy.rawValue, forKey: groupDimKey)
        collapsedGroups.removeAll()   // dimension/on-off changed → group keys differ
        rebuildColumns()
        applyFilter()
    }

    private func toggleGroupCollapse(_ key: String) {
        if collapsedGroups.contains(key) { collapsedGroups.remove(key) } else { collapsedGroups.insert(key) }
        applyFilter()
    }

    private func rebuildColumns() {
        table.autosaveName = nil   // don't let teardown overwrite the previous kind's saved layout
        for column in table.tableColumns { table.removeTableColumn(column) }

        var defs = kind.columns
        if groupBy != .namespace && kind.isNamespaced && !defs.contains(where: { $0.id == "namespace" }) {
            // Not grouping by namespace → show it as a column (flat, or grouped by
            // node/status/…) — unless the kind already places one (events). Cluster-
            // scoped kinds (nodes) have no namespace, so no column either.
            defs.insert(ResourceColumn(id: "namespace", title: "Namespace", width: 200, minWidth: 120, style: .plain), at: 0)
        }
        // Layout autosave: grouped-by-namespace hides the ns column; every other mode
        // shows it, so they share one "_flat" layout per kind.
        table.autosaveName = "KubColumns_\(kind.rawValue)\(groupBy == .namespace ? "" : "_flat")"
        for def in defs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.width = def.width
            col.minWidth = def.minWidth
            if def.style == .mono { col.headerCell.alignment = .right }   // numeric columns
            col.sortDescriptorPrototype = NSSortDescriptor(key: def.id, ascending: true)
            table.addTableColumn(col)
        }
        if kind.primaryAction != nil {
            let actions = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(actionsColumnId))
            actions.title = ""
            actions.width = 40
            actions.minWidth = 40
            actions.maxWidth = 40
            table.addTableColumn(actions)
        }
        buildHeaderMenu()
        // Fit to content on open UNLESS the user has a saved (manually-resized)
        // column layout for this kind — then their widths win. "compact by
        // default, resizes stick." A programmatic fit isn't autosaved, so a kind
        // the user never resized re-fits on every open (stays compact).
        pendingFit = !hasSavedColumnLayout
    }

    /// True once the user has manually resized/reordered this layout's columns —
    /// NSTableView's autosave then persists a "Columns" entry for the autosave name.
    private var hasSavedColumnLayout: Bool {
        guard let name = table.autosaveName else { return false }
        return UserDefaults.standard.dictionaryRepresentation().keys.contains {
            $0.hasPrefix("NSTableView Columns") && $0.hasSuffix(name)
        }
    }

    /// Size each visible column to the minimum that shows its content (header +
    /// widest cell). Skips the fixed action column. Honors the per-style font/inset.
    private func fitColumnsToContent() {
        for column in table.tableColumns where !column.isHidden {
            let id = column.identifier.rawValue
            if id == actionsColumnId { continue }
            let style: ResourceColumn.Style = id == "namespace"
                ? .plain
                : (kind.columns.first { $0.id == id }?.style ?? .plain)
            let font: NSFont
            let padding: CGFloat
            let maxW: CGFloat
            switch style {
            case .status:     font = .systemFont(ofSize: 12);                                   padding = 38; maxW = 460
            case .statusText: font = .systemFont(ofSize: 12);                                   padding = 38; maxW = 200   // icon now lives here
            case .plain:      font = .systemFont(ofSize: 12);                                   padding = 22; maxW = 460
            case .mono:       font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular);  padding = 22; maxW = 150
            case .badge:      font = .systemFont(ofSize: 11, weight: .semibold);                padding = 32; maxW = 120
            }
            column.width = ColumnFit.width(title: column.title, texts: rows.map { $0.value(id) },
                                           font: font, padding: padding, minWidth: column.minWidth, maxWidth: maxW)
        }
    }

    /// Right-click menu on the column header — toggle column visibility (standard idiom).
    private func buildHeaderMenu() {
        let menu = NSMenu()
        for column in table.tableColumns where !column.title.isEmpty {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
        table.headerView?.menu = menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        sender.state = column.isHidden ? .off : .on
    }

    // MARK: - Public update

    func update(rows: [ResourceRow]) {
        allRows = rows
        applyFilter()
    }

    func setQuery(_ q: String) {
        query = q
        applyFilter()
    }

    func setHideSystemNamespaces(_ hide: Bool) {
        hideSystem = hide
        applyFilter()
    }

    /// The bookmark toolbar toggle: when on, show only rows in pinned namespaces.
    /// Also drives the pinned bookmark glyph on group headers, so pass the set even
    /// when off (a pin/unpin refreshes the glyphs without changing the filter).
    func setBookmarkFilter(_ on: Bool, pinned: Set<String>) {
        pinnedOnly = on
        pinnedNamespaces = pinned
        applyFilter()
    }

    func setLoading(_ loading: Bool, message: String?) {
        isLoading = loading
        loadingMessage = message
        refreshEmptyLabel()
    }

    func setError(_ message: String?) {
        lastError = message
        refreshEmptyLabel()
    }

    /// Thin colored stripe under the toolbar, over the content area (not the sidebar).
    func setContextBandColor(_ color: NSColor?) {
        contextBand.layer?.backgroundColor = (color ?? .clear).cgColor
        contextBand.isHidden = (color == nil)
        contextBandHeight.constant = (color == nil) ? 0 : 2
    }

    func setStatusLine(_ text: String, isCommand: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = .secondaryLabelColor
        if text.isEmpty {
            statusSpinner.stopAnimation(nil)
        } else {
            statusSpinner.startAnimation(nil)
        }
    }

    // MARK: - Filtering / sorting / grouping

    private func applyFilter() {
        let previous = selectedKey()

        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered = allRows.filter { row in
            // Bookmark toggle: keep only rows in a pinned namespace (cluster-scoped
            // rows have no pinnableNamespace, so they're never blanked by it).
            if pinnedOnly, let ns = row.pinnableNamespace, !pinnedNamespaces.contains(ns) { return false }
            if hideSystem && row.isSystemNamespace { return false }
            if q.isEmpty { return true }
            return row.namespace.lowercased().contains(q) || row.name.lowercased().contains(q)
        }

        filtered.sort { a, b in
            if groupBy != nil {
                let ka = groupKey(a), kb = groupKey(b)
                if ka != kb { return ka.localizedCaseInsensitiveCompare(kb) == .orderedAscending }
            }
            if let key = sortColumn {
                let result = a.compare(to: b, column: key)
                if result != .orderedSame {
                    return sortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
                }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        rows = filtered

        if groupBy != nil {
            var built: [Item] = []
            var lastKey: String?
            for row in rows {
                let key = groupKey(row)
                if key != lastKey {
                    built.append(.group(key))
                    lastKey = key
                }
                if !collapsedGroups.contains(key) { built.append(.row(row)) }   // hide rows of collapsed groups
            }
            items = built
        } else {
            items = rows.map { .row($0) }
        }

        table.reloadData()
        reselect(previous)
        applyPendingReveal()   // a node→pod jump may be waiting for this list to load
        refreshEmptyLabel()
        requestDetailReload(force: false)

        if pendingFit, !rows.isEmpty {
            fitColumnsToContent()
            pendingFit = false
        }
    }

    private func refreshEmptyLabel() {
        // Show an error centered in the content area (instead of the table) when
        // there's nothing to show; keep stale rows visible if a poll errors later.
        if isLoading {
            emptyLabel.stringValue = loadingMessage ?? "Loading…"
            emptyLabel.textColor = .labelColor
            emptyLabel.setActionButton(nil)
        } else if let error = lastError, allRows.isEmpty {
            emptyLabel.stringValue = "⚠︎  " + error
            emptyLabel.textColor = .systemRed
            emptyLabel.setActionButton("Reload") { [weak self] in self?.onReloadRequested?() }
        } else if allRows.isEmpty {
            emptyLabel.stringValue = "No \(kind.displayName.lowercased())"
            emptyLabel.textColor = .labelColor
            emptyLabel.setActionButton(nil)
        } else {
            let bookmarkIsCause = pinnedOnly && query.trimmingCharacters(in: .whitespaces).isEmpty
            emptyLabel.stringValue = bookmarkIsCause
                ? (pinnedNamespaces.isEmpty ? "No pinned namespaces" : "No matches in pinned namespaces")
                : "No matches"
            emptyLabel.textColor = .labelColor
            // Offer a reset for whichever filter is actually the cause.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyLabel.setActionButton("Clear filter") { [weak self] in self?.onClearFilter?() }
            } else if pinnedOnly {
                emptyLabel.setActionButton("Show all") { [weak self] in self?.onClearBookmarkFilter?() }
            } else {
                emptyLabel.setActionButton(nil)
            }
        }
        emptyLabel.isHidden = !rows.isEmpty
    }

    // MARK: - Selection

    private func selectedKey() -> String? {
        let r = table.selectedRow
        guard r >= 0, r < items.count, case let .row(row) = items[r] else { return nil }
        return row.key
    }

    /// Anchor (view + rect) for a confirm popover on a specific row.
    func rowAnchor(for row: ResourceRow) -> (NSView, NSRect)? {
        guard let idx = items.firstIndex(where: {
            if case let .row(r) = $0 { return r.key == row.key } else { return false }
        }) else { return nil }
        return (table, table.rect(ofRow: idx))
    }

    /// Anchor for a confirm/info popover over the detail pane (process diagnostics).
    func detailAnchor() -> (NSView, NSRect) { (detailPane, detailPane.bounds) }

    private func reselect(_ key: String?) {
        guard let key else { return }
        for (i, item) in items.enumerated() {
            if case let .row(row) = item, row.key == key {
                programmaticSelect(i)
                return
            }
        }
    }

    // MARK: - Actions / menu

    @objc private func primaryActionFromMenu(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? ResourceRow { onPrimaryAction?(row) }
    }

    @objc private func scaleFromMenu(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? ResourceRow { onScaleAction?(row) }
    }

    @objc private func rollbackFromMenu(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? ResourceRow { onRollbackAction?(row) }
    }

    @objc private func togglePinFromMenu(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? ResourceRow { onTogglePin?(row) }
    }

    @objc private func portForwardFromMenu(_ sender: NSMenuItem) {
        if let row = sender.representedObject as? ResourceRow { onPortForward?(row) }
    }

    @objc private func copyName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    private func rowMenu(_ rowIndex: Int, column: Int) -> NSMenu? {
        guard rowIndex >= 0, rowIndex < items.count, case let .row(row) = items[rowIndex] else { return nil }
        let menu = NSMenu()
        if let action = row.kind.primaryAction {
            let title = "\(action.title) \(row.kind.singularName.capitalized)…"
            let item = NSMenuItem(title: title, action: #selector(primaryActionFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row
            menu.addItem(item)
        }
        if row.kind.scalable {
            let scale = NSMenuItem(title: "Scale \(row.kind.singularName.capitalized)…",
                                   action: #selector(scaleFromMenu(_:)), keyEquivalent: "")
            scale.target = self
            scale.representedObject = row
            menu.addItem(scale)
        }
        if row.kind.rollbackable {
            let rb = NSMenuItem(title: "Roll Back \(row.kind.singularName.capitalized)…",
                                action: #selector(rollbackFromMenu(_:)), keyEquivalent: "")
            rb.target = self
            rb.representedObject = row
            menu.addItem(rb)
        }
        if PortForwardController.canForward(row.kind) {
            let pf = NSMenuItem(title: "Port-Forward…", action: #selector(portForwardFromMenu(_:)), keyEquivalent: "")
            pf.target = self
            pf.representedObject = row
            menu.addItem(pf)
        }
        if row.kind.primaryAction != nil || row.kind.scalable || row.kind.rollbackable
            || PortForwardController.canForward(row.kind) { menu.addItem(.separator()) }
        if let ns = row.pinnableNamespace {   // pin the row's namespace as a bookmark
            let pinned = isPinned?(row) ?? false
            let pin = NSMenuItem(title: pinned ? "Unpin Namespace “\(ns)”" : "Pin Namespace “\(ns)”",
                                 action: #selector(togglePinFromMenu(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = row
            menu.addItem(pin)
        }
        if let item = CellCopy.menuItem(table, row: rowIndex, column: column) {
            menu.addItem(item)   // "Copy <Column>" — copies the exact clicked cell
        }
        let copy = NSMenuItem(title: "Copy Name", action: #selector(copyName(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = row.name
        menu.addItem(copy)
        return menu
    }
}

// MARK: - Table data source / delegate

extension ResourceListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = items[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A real user click cancels a still-pending reveal so it can't later jump
        // the selection off the row the user just chose.
        if !settingSelectionProgrammatically { pendingReveal = nil }
        requestDetailReload(force: false)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if let descriptor = tableView.sortDescriptors.first {
            sortColumn = descriptor.key
            sortAscending = descriptor.ascending
        } else {
            sortColumn = nil
        }
        applyFilter()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .group(let namespace):
            return groupCell(namespace)
        case .row(let item):
            guard let colId = tableColumn?.identifier.rawValue else { return nil }
            if colId == actionsColumnId { return actionCell(for: item) }
            if item.kind == .namespaces, colId == "name" { return namespaceRowCell(item) }
            if colId == "namespace" { return bookmarkCell(item.namespace, dimmed: true) }   // flat view's Namespace column
            return dataCell(for: item, columnId: colId)
        }
    }

    private func dataCell(for item: ResourceRow, columnId: String) -> NSView {
        // The health status icon lives in the Status column when the kind has one;
        // the name column is then plain. Kinds without a Status column (events,
        // config/network kinds) keep the icon on the name — their only indicator.
        let style: ResourceColumn.Style = columnId == "namespace"
            ? .plain
            : (kind.columns.first { $0.id == columnId }?.style ?? .plain)
        let hasStatusColumn = kind.columns.contains { $0.style == .statusText }

        if style == .badge {
            let cell = (table.makeView(withIdentifier: BadgeCellView.id, owner: self) as? BadgeCellView)
                ?? {
                    let c = BadgeCellView()
                    c.identifier = BadgeCellView.id
                    return c
                }()
            let value = item.value(columnId)
            cell.configure(value, color: ArchBadge.color(for: value))
            return cell
        }

        let cell = (table.makeView(withIdentifier: StatusCellView.id, owner: self) as? StatusCellView)
            ?? {
                let c = StatusCellView()
                c.identifier = StatusCellView.id
                return c
            }()
        cell.toolTip = nil   // reset — reused cells only keep a tooltip where set (age)
        switch style {
        case .status:
            if hasStatusColumn || item.statusKind == .neutral {
                // No kind icon in the table — it lives in the sidebar + detail header.
                // Health status (non-neutral) keeps its icon; neutral kinds go plain.
                cell.configurePlain(item.value(columnId))
            } else {
                cell.configure(kind: item.statusKind, text: item.value(columnId))
            }
        case .statusText:
            if item.statusKind == .neutral {
                cell.configurePlain(item.statusText, secondary: true)   // status word only, no kind icon
            } else {
                cell.configure(kind: item.statusKind, text: item.statusText)
            }
        case .plain:
            if columnId == "namespace" {
                cell.configureNamespace(item.value(columnId))
            } else {
                cell.configurePlain(item.value(columnId))
            }
        case .mono:
            let value = item.value(columnId)
            cell.configurePlain(value, monospacedDigits: true,
                                secondary: value == "—", alignment: .right)   // age now normal colour
            if columnId == "age", let created = item.cells["created"], !created.isEmpty {
                cell.toolTip = created   // exact creation date-time on hover
            }
        case .badge:
            break   // handled above via BadgeCellView
        }
        return cell
    }

    private func actionCell(for item: ResourceRow) -> NSView {
        let cell = (table.makeView(withIdentifier: MiniActionCell.id, owner: self) as? MiniActionCell)
            ?? {
                let c = MiniActionCell()
                c.identifier = MiniActionCell.id
                return c
            }()
        guard let action = item.kind.primaryAction else { return NSView() }
        let symbol = action == .delete ? "trash" : "arrow.clockwise"
        let tint: NSColor = action == .delete ? .systemRed : .controlAccentColor
        let tip = "\(action.title) \(item.kind.singularName)"
        cell.configure(symbol: symbol, tooltip: tip, tint: tint) { [weak self] in
            self?.onPrimaryAction?(item)
        }
        return cell
    }

    private func groupCell(_ value: String) -> NSView {
        // Namespace groups get the clickable paw bookmark; other dimensions (node /
        // status / workload) are plain headers. Both carry a collapse disclosure.
        let collapsed = collapsedGroups.contains(value)
        let toggle: () -> Void = { [weak self] in self?.toggleGroupCollapse(value) }
        return groupBy == .namespace
            ? bookmarkCell(value, dimmed: true, collapsed: collapsed, onToggleCollapse: toggle)
            : plainGroupCell(value, collapsed: collapsed, onToggleCollapse: toggle)
    }

    private func plainGroupCell(_ value: String, collapsed: Bool, onToggleCollapse: @escaping () -> Void) -> NSView {
        let cell = (table.makeView(withIdentifier: GroupIconHeaderCell.id, owner: self) as? GroupIconHeaderCell)
            ?? GroupIconHeaderCell()
        cell.configure(symbol: groupHeaderIcon(for: value), text: value,
                       collapsed: collapsed, onToggleCollapse: onToggleCollapse)
        return cell
    }

    /// The resource-type icon for a group header, per the active dimension: Node → the
    /// node icon, Workload → the workload's own kind icon. Status isn't a resource type.
    private func groupHeaderIcon(for value: String) -> String? {
        switch groupBy {
        case .node: return ResourceKind.nodes.symbol
        case .workload:
            let kindName = value.split(separator: "/").first.map(String.init) ?? ""
            return ResourceKind.allCases.first { $0.singularName.caseInsensitiveCompare(kindName) == .orderedSame }?.symbol
                ?? ResourceKind.deployments.symbol
        default: return nil
        }
    }

    /// The Namespaces-table name column: each row *is* a namespace (primary text).
    private func namespaceRowCell(_ item: ResourceRow) -> NSView {
        bookmarkCell(item.name, dimmed: false)
    }

    private func bookmarkCell(_ namespace: String, dimmed: Bool,
                              collapsed: Bool? = nil, onToggleCollapse: (() -> Void)? = nil) -> NSView {
        let cell = (table.makeView(withIdentifier: NamespaceBookmarkCell.id, owner: self) as? NamespaceBookmarkCell)
            ?? NamespaceBookmarkCell()
        cell.configure(namespace: namespace, pinned: pinnedNamespaces.contains(namespace), dimmed: dimmed,
                       collapsed: collapsed, onToggleCollapse: onToggleCollapse) { [weak self] in
            self?.onTogglePinNamespace?(namespace)
        }
        return cell
    }
}

/// A namespace label with a clickable bookmark that pins/unpins it on the spot.
/// Reused anywhere a namespace name is shown — a grouped table's group header
/// (`header: true`) and a row in the Namespaces table (`header: false`) — so the
/// bookmark appears everywhere there's a namespace. Filled/accent when pinned,
/// hollow/secondary when not; white on a selected row.
final class NamespaceBookmarkCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("NamespaceBookmarkCell")
    private let chevron = GroupDisclosure()
    private let bookmark = NSButton()
    private let label = NSTextField(labelWithString: "")
    private var onToggle: (() -> Void)?
    private var pinned = false
    private var baseColor: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.id
        bookmark.isBordered = false
        bookmark.bezelStyle = .regularSquare
        bookmark.imagePosition = .imageOnly
        bookmark.setButtonType(.momentaryChange)
        bookmark.target = self
        bookmark.action = #selector(toggle)
        bookmark.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(chevron)
        addSubview(bookmark)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            bookmark.leadingAnchor.constraint(equalTo: chevron.trailingAnchor),
            bookmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            bookmark.widthAnchor.constraint(equalToConstant: 18),
            bookmark.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: bookmark.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(namespace: String, pinned: Bool, dimmed: Bool,
                   collapsed: Bool? = nil, onToggleCollapse: (() -> Void)? = nil,
                   onToggle: @escaping () -> Void) {
        self.pinned = pinned
        self.onToggle = onToggle
        chevron.configure(collapsed: collapsed, onToggle: onToggleCollapse)
        label.stringValue = namespace
        label.font = .systemFont(ofSize: 12, weight: dimmed ? .semibold : .regular)
        baseColor = dimmed ? .secondaryLabelColor : .labelColor
        let tip = pinned ? "Unpin namespace “\(namespace)”" : "Pin namespace “\(namespace)”"
        bookmark.toolTip = tip
        toolTip = tip   // show the hint when hovering anywhere in the namespace cell, too
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()   // re-bake the symbol colour for the new light/dark appearance
    }

    // Brighten the unpinned paw while the pointer is over its namespace cell.
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self)
        addTrackingArea(t)
        trackingArea = t
    }
    override func mouseEntered(with event: NSEvent) { applyColors() }
    override func mouseExited(with event: NSEvent) { applyColors() }

    /// Live pointer test — reload-safe (a stored flag would go stale on the 5s poll).
    private var isHovered: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// The colour is *baked into* the symbol (palette config) rather than applied via
    /// contentTintColor, so it survives the vibrancy of a group-row header (a
    /// template-tinted image washed out there and looked missing). Always the outline
    /// paw — only the stroke colour changes.
    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        label.textColor = selected ? .alternateSelectedControlTextColor : baseColor
        let color: NSColor
        if selected { color = .alternateSelectedControlTextColor }   // white on the highlight
        else if pinned { color = .controlAccentColor }               // blue outline
        else { color = isHovered ? .secondaryLabelColor : .tertiaryLabelColor }  // faint, brighter on hover
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        // A bear-cub paw is Kub's take on a bookmark (the mascot is a polar-bear cub).
        bookmark.image = NSImage(systemSymbolName: "pawprint",
                                 accessibilityDescription: pinned ? "Unpin namespace" : "Pin namespace")?
            .withSymbolConfiguration(cfg)
    }

    @objc private func toggle() { onToggle?() }
}

/// Group header for a non-namespace dimension: an optional resource-type icon
/// (node / workload) + the group value.
final class GroupIconHeaderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("PlainGroupHeader")
    private let chevron = GroupDisclosure()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.id
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(chevron)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(symbol: String?, text: String, collapsed: Bool, onToggleCollapse: @escaping () -> Void) {
        chevron.configure(collapsed: collapsed, onToggle: onToggleCollapse)
        if let symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            icon.isHidden = false
            iconWidth.constant = 14
        } else {
            icon.image = nil
            icon.isHidden = true
            iconWidth.constant = 0
        }
        label.stringValue = text
    }
}

/// A collapse/expand disclosure chevron for a group header — ▸ collapsed, ▾ open.
/// Zero-width and hidden when the cell isn't a group header (`collapsed == nil`).
final class GroupDisclosure: NSButton {
    private var onToggle: (() -> Void)?
    private var widthC: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthC = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([widthC, heightAnchor.constraint(equalToConstant: 14)])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(collapsed: Bool?, onToggle: (() -> Void)?) {
        self.onToggle = onToggle
        guard let collapsed else { image = nil; isHidden = true; widthC.constant = 0; return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                        accessibilityDescription: collapsed ? "Expand" : "Collapse")?.withSymbolConfiguration(cfg)
        isHidden = false
        widthC.constant = 14
    }
    @objc private func clicked() { onToggle?() }
}

// MARK: - Detail split sizing

extension ResourceListViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + 120   // table keeps at least 120pt
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - 140   // detail pane keeps at least 140pt
    }
}
