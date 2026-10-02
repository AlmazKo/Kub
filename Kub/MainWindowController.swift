import AppKit

extension NSToolbarItem.Identifier {
    static let context = NSToolbarItem.Identifier("context")
    static let group = NSToolbarItem.Identifier("group")
    static let details = NSToolbarItem.Identifier("details")
    static let forwards = NSToolbarItem.Identifier("forwards")
    static let activity = NSToolbarItem.Identifier("activity")
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let search = NSToolbarItem.Identifier("search")
    static let bookmark = NSToolbarItem.Identifier("bookmark")
}

private let hideSystemDefaultsKey = "HideSystemNamespaces"
private let showDetailsDefaultsKey = "ShowDetails"
private let bookmarkFilterDefaultsKey = "BookmarkFilterOn"

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private let viewModel: ClusterViewModel
    private let splitVC = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let resourceList = ResourceListViewController()
    private var hideSystemNamespaces: Bool
    private var showDetails: Bool
    private var bookmarkFilterOn: Bool
    private var detailTask: Task<Void, Never>?
    private var logStream: KubectlProcess?   // live `logs -f` follow (Logs tab)
    private var logStreamGeneration = 0       // gates late callbacks from a superseded stream
    private var diagnosticTasks: Set<Task<Void, Never>> = []
    private lazy var portForwards = PortForwardController(viewModel: viewModel)
    private let activity = ActivityController()

    private func stopLogStream() { logStream?.stop(); logStream = nil; logStreamGeneration &+= 1 }

    private let groupMenu = NSMenu()   // Finder-style Group menu, popped on click (fully ours)
    private lazy var groupButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Group")!,
                         target: self, action: #selector(showGroupMenu(_:)))
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.toolTip = "Group rows by…"
        return b
    }()

    private lazy var detailsButton: NSButton = {
        let b = NSButton(image: detailsImage(on: showDetails), target: self, action: #selector(toggleDetails(_:)))
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .texturedRounded
        b.toolTip = "Show detail panel (Overview / Logs / Events) — ⌘⇧D"
        b.state = showDetails ? .on : .off
        return b
    }()

    /// Filled bottom-third when the pane is shown, a bare outline when hidden — the
    /// glass toolbar doesn't render a push-on/push-off state, so the glyph carries it
    /// (same trick as the bookmark paw).
    private func detailsImage(on: Bool) -> NSImage {
        NSImage(systemSymbolName: on ? "rectangle.bottomthird.inset.filled" : "rectangle",
                accessibilityDescription: "Details")!
    }

    private lazy var bookmarkButton: NSButton = {
        let symbol = bookmarkFilterOn ? "pawprint.fill" : "pawprint"   // bear-cub paw = Kub's bookmark
        let b = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: "Bookmarks")!,
            target: self, action: #selector(toggleBookmarkFilter(_:)))
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .texturedRounded
        b.toolTip = "Show only pinned namespaces"
        b.state = bookmarkFilterOn ? .on : .off
        return b
    }()

    private lazy var forwardsButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "network", accessibilityDescription: "Port-forwards")!,
                         target: self, action: #selector(showForwards(_:)))
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.toolTip = "Active port-forwards"
        b.isEnabled = false   // nothing to show until a session starts
        return b
    }()

    @objc private func showForwards(_ sender: Any?) {
        portForwards.showSessions(anchor: forwardsButton, rect: forwardsButton.bounds)
    }

    private lazy var activityButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Tasks")!,
                         target: self, action: #selector(showActivity(_:)))
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.toolTip = "Running tasks (heap dump / profile)"
        b.isEnabled = false   // nothing to show until a task starts
        return b
    }()

    @objc private func showActivity(_ sender: Any?) {
        activity.show(anchor: activityButton, rect: activityButton.bounds)
    }

    private lazy var contextPopup: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.target = self
        p.action = #selector(contextChanged(_:))
        p.toolTip = "Active cluster context — applies to the whole window"
        p.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return p
    }()

    private static let customizeMenuTag = 7777


    private var customizePopover: NSPopover?

    private lazy var searchField: NSSearchField = {
        let f = NSSearchField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.placeholderString = "Filter"
        f.delegate = self
        f.sendsWholeSearchString = false
        f.sendsSearchStringImmediately = true
        f.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return f
    }()

    init() {
        viewModel = ClusterViewModel(service: KubectlClient())
        hideSystemNamespaces = UserDefaults.standard.bool(forKey: hideSystemDefaultsKey)
        showDetails = UserDefaults.standard.object(forKey: showDetailsDefaultsKey) as? Bool ?? true
        bookmarkFilterOn = UserDefaults.standard.bool(forKey: bookmarkFilterDefaultsKey)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Kub"
        window.titleVisibility = .hidden
        // Let the sidebar material run up behind the traffic lights (Finder-style).
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 640, height: 480)
        // Bumped suffix invalidates the old saved frame so the new default applies.
        window.setFrameAutosaveName("KubMainWindow4")
        window.delegate = self

        configureSplit()
        configureToolbar()

        window.contentViewController = splitVC
        sidebar.loadViewIfNeeded()
        resourceList.loadViewIfNeeded()
        window.initialFirstResponder = searchField

        resourceList.configure(for: viewModel.selectedKind)
        sidebar.setSelectedKind(viewModel.selectedKind)
        resourceList.setHideSystemNamespaces(hideSystemNamespaces)
        applyBookmarkFilter()

        bindViewModel()
        updateGroupItemState()      // enable/disable the Group island per kind
        resourceList.setDetailVisible(showDetails)
        window.center()
        viewModel.start()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        ensureComfortableSize()
    }

    /// Grow the window to a comfortable launch size if a (small) saved frame was
    /// restored — clamped to the visible screen so it always fits.
    private func ensureComfortableSize() {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1280, height: 800)
        let target = NSSize(width: min(1200, visible.width - 40),
                            height: min(720, visible.height - 40))
        var frame = window.frame
        if frame.width >= target.width && frame.height >= target.height { return }
        frame.size.width = max(frame.width, target.width)
        frame.size.height = max(frame.height, target.height)
        window.setFrame(frame, display: true)
        window.center()
    }

    // MARK: - Setup

    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 212
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = false          // always-visible, full-height sidebar

        let contentItem = NSSplitViewItem(viewController: resourceList)
        contentItem.minimumThickness = 380

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        splitVC.splitView.autosaveName = "KubMainSplit"   // remember the sidebar width
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "KubToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func bindViewModel() {
        sidebar.onSelectKind = { [weak self] kind in
            guard let self else { return }
            Task { await self.viewModel.selectKind(kind) }
        }
        sidebar.onToggleKind = { [weak self] kind, enabled in
            guard let self else { return }
            if enabled {
                viewModel.refreshCount(for: kind)
            } else if viewModel.selectedKind == kind,
                      let next = ResourceKind.allCases.first(where: { $0 != kind && ResourceKindStore.isEnabled($0) }) {
                Task { await self.viewModel.selectKind(next) }
            }
        }

        viewModel.onContextsChanged = { [weak self] in
            guard let self else { return }
            updateContextPopup()
            applyBookmarkFilter()                           // pinned namespaces are per-context
            resourceList.contextChanged()                   // same-key row → force detail reload for the new context
        }
        viewModel.onKindChanged = { [weak self] in
            guard let self else { return }
            resourceList.configure(for: viewModel.selectedKind)
            resourceList.setHideSystemNamespaces(hideSystemNamespaces)
            sidebar.setSelectedKind(viewModel.selectedKind)
            updateGroupItemState()
        }
        viewModel.onResourcesChanged = { [weak self] in
            guard let self else { return }
            resourceList.update(rows: viewModel.rows)
        }
        viewModel.onCountsChanged = { [weak self] in
            guard let self else { return }
            sidebar.setCounts(viewModel.kindCounts)
            sidebar.setEventsUnread(viewModel.unreadEvents)
        }
        viewModel.onStateChanged = { [weak self] in
            guard let self else { return }
            resourceList.setLoading(viewModel.isLoading, message: viewModel.activity)
            resourceList.setError(viewModel.lastError)
            resourceList.setStatusLine(viewModel.statusLine, isCommand: !viewModel.statusLine.isEmpty)
        }

        resourceList.onPrimaryAction = { [weak self] row in self?.confirmPrimaryAction(row) }
        resourceList.onScaleAction = { [weak self] row in self?.confirmScale(row) }
        resourceList.onRollbackAction = { [weak self] row in self?.confirmRollback(row) }
        resourceList.isPinned = { [weak self] row in
            guard let ctx = self?.viewModel.selectedContext, let ns = row.pinnableNamespace else { return false }
            return PinnedNamespaces.isPinned(ns, in: ctx)
        }
        resourceList.onTogglePin = { [weak self] row in
            guard let self, let ns = row.pinnableNamespace else { return }
            togglePinnedNamespace(ns)
        }
        resourceList.onTogglePinNamespace = { [weak self] ns in self?.togglePinnedNamespace(ns) }
        resourceList.onPortForward = { [weak self] row in
            guard let self, let (anchor, rect) = resourceList.rowAnchor(for: row) else { return }
            portForwards.begin(for: row, anchor: anchor, rect: rect)
        }
        portForwards.onCountChanged = { [weak self] count in
            guard let self else { return }
            forwardsButton.title = count > 0 ? "  \(count)" : ""
            forwardsButton.imagePosition = count > 0 ? .imageLeading : .imageOnly
            forwardsButton.isEnabled = count > 0
        }
        activity.onCountChanged = { [weak self] count in
            guard let self else { return }
            activityButton.title = count > 0 ? "  \(count)" : ""
            activityButton.imagePosition = count > 0 ? .imageLeading : .imageOnly
            activityButton.isEnabled = count > 0
        }
        resourceList.onDetailReloadRequested = { [weak self] in self?.reloadDetail() }
        resourceList.onReloadRequested = { [weak self] in self?.refresh(nil) }
        resourceList.onClearFilter = { [weak self] in
            guard let self else { return }
            searchField.stringValue = ""
            resourceList.setQuery("")
        }
        resourceList.onClearBookmarkFilter = { [weak self] in
            guard let self, bookmarkFilterOn else { return }
            toggleBookmarkFilter(nil)   // turn the bookmark filter off (updates button + table)
        }
        resourceList.onTableTypeSearch = { [weak self] char in self?.beginTableSearch(char) }
        resourceList.onTableEscape = { [weak self] in self?.clearTableSearch() }
        resourceList.onProcessAction = { [weak self] action in self?.handleProcessAction(action) }
        resourceList.onOpenPod = { [weak self] ns, name in self?.openPod(namespace: ns, name: name) }
        resourceList.onOpenResource = { [weak self] kind, ns, name in self?.openResource(kind, namespace: ns, name: name) }
        resourceList.onReloadMetrics = { [weak self] endpoint in self?.loadMetrics(override: endpoint) }
    }

    /// IDEA-style speed-search on the main table: a printable key grows the toolbar
    /// filter and moves focus to it; Esc clears.
    private func beginTableSearch(_ char: String) {
        if searchField.stringValue.isEmpty, char == " " { return }
        searchField.stringValue += char
        resourceList.setQuery(searchField.stringValue)
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
    }

    private func clearTableSearch() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        resourceList.setQuery("")
    }

    /// (Re)scrape the selected pod's metrics for an explicit endpoint chosen in the
    /// Metrics tab (port/path override). Separate from `reloadDetail` because it's
    /// driven by the tab's own controls, not a section change.
    private func loadMetrics(override: MetricEndpoint) {
        guard showDetails, let row = resourceList.selectedRow, row.kind == .pods else { return }
        detailTask?.cancel()
        stopLogStream()
        resourceList.setDetailLoading("Loading metrics…")
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await viewModel.podMetrics(for: row, override: override)
                if Task.isCancelled { return }
                resourceList.setDetailMetrics(report)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                resourceList.setDetailMetrics(MetricsReport(endpoint: override, document: MetricsDocument(),
                    note: "Error: \(error.localizedDescription)"))
            }
        }
    }

    /// Jump from a node's Pods table to that pod in the Pods section.
    private func openPod(namespace: String, name: String) {
        searchField.stringValue = ""
        resourceList.setQuery("")               // clear any filter so the target is visible
        resourceList.reveal(namespace: namespace, name: name)
        if viewModel.selectedKind != .pods {
            Task { await viewModel.selectKind(.pods) }   // reveal applies when the list loads
        }
    }

    /// Jump from a namespace's inventory to a specific resource in its section.
    private func openResource(_ kind: ResourceKind, namespace: String, name: String) {
        if !ResourceKindStore.isEnabled(kind) {   // surface a hidden kind we're navigating to
            ResourceKindStore.setEnabled(kind, true)
            sidebar.reloadKinds()
            viewModel.refreshCount(for: kind)
        }
        searchField.stringValue = ""
        resourceList.setQuery("")                  // clear any filter so the target is visible
        resourceList.reveal(namespace: namespace, name: name)
        if viewModel.selectedKind != kind {
            Task { await viewModel.selectKind(kind) }   // reveal applies when the list loads
        }
    }

    // MARK: - Detail panel

    /// `showLoading: false` re-arms the loop without flashing a "Loading…" reset —
    /// used when resuming after a modal so the live Top table keeps its rows,
    /// sort, and selection until fresh data lands in place.
    private func reloadDetail(showLoading: Bool = true) {
        guard showDetails else { return }
        detailTask?.cancel()
        stopLogStream()
        guard let row = resourceList.selectedRow else {
            resourceList.setDetailSections([])   // hide the tab switcher
            resourceList.setDetailTitle(symbol: nil, "No selection")
            resourceList.setDetailText("Select a row to see details.")
            return
        }
        resourceList.setDetailSections(row.kind.detailSections)
        let section = resourceList.detailSection
        let target = row.namespace.isEmpty ? row.name : "\(row.namespace)/\(row.name)"
        resourceList.setDetailTitle(symbol: row.kind.symbol, target)
        // The Top tab (pods only) live-updates; everything else is a one-shot load.
        let isLive = section == .top && row.kind == .pods
        let isNodePods = section == .pods && row.kind == .nodes
        let isNamespaceInv = section == .resources && row.kind == .namespaces
        let isMetrics = section == .metrics && row.kind == .pods
        let isEvents = section == .events

        // The Shell tab hosts a live SwiftTerm exec; configure() keeps a running
        // session for the same pod, switches it for a different pod. Leaving the
        // tab (any non-shell path below) ends the session.
        if section == .shell && row.kind == .pods {
            resourceList.configureDetailShell(context: viewModel.selectedContext ?? "",
                                              namespace: row.namespace, pod: row.name,
                                              isProduction: contextIsDangerous)
            return
        }
        resourceList.stopDetailShell()

        // The Logs tab (pods) follows via a streaming process, not a polled task.
        if section == .logs && row.kind == .pods {
            let gen = logStreamGeneration   // stopLogStream() above bumped it; this is the current stream
            resourceList.startDetailLiveLog()
            let pump = LogPump { [weak self] lines in
                guard let self, self.logStreamGeneration == gen else { return }
                self.resourceList.appendDetailLiveLog(lines)
            }
            logStream = viewModel.streamLogs(
                for: row,
                onLine: { pump.push($0) },
                onEnd: { [weak self] err in
                    let note = err.map { "— log stream ended: \($0.message) —" } ?? "— log stream ended —"
                    DispatchQueue.main.async {
                        guard let self, self.logStreamGeneration == gen else { return }
                        self.resourceList.appendDetailLiveLog([note])
                    }
                })
            return
        }

        // Show the last cached result instantly (no spinner); the task below still
        // refreshes it. A loading message only appears when nothing is cached.
        var showedCache = false
        if isLive {
            if let r = viewModel.cachedTop(for: row) { resourceList.setDetailTopReport(r); showedCache = true }
        } else if isNodePods {
            if let p = viewModel.cachedNodePods(for: row) { resourceList.setDetailNodePods(p); showedCache = true }
        } else if isNamespaceInv {
            if let items = viewModel.cachedInventory(for: row) { resourceList.setDetailInventory(items, namespace: row.name); showedCache = true }
        } else if isMetrics {
            if let m = viewModel.cachedMetrics(for: row) { resourceList.setDetailMetrics(m); showedCache = true }
        } else if isEvents {
            if let e = viewModel.cachedResourceEvents(for: row) { resourceList.setDetailEvents(e); showedCache = true }
        } else if let t = viewModel.cachedDetailText(for: row, section: section) {
            resourceList.setDetailText(t); showedCache = true
        }

        if showLoading && !showedCache {
            if isNamespaceInv { resourceList.setDetailInventoryLoading() }
            else { resourceList.setDetailLoading("Loading \(section.title.lowercased())…") }
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if isLive {
                        let report = try await viewModel.detailTop(for: row)
                        if Task.isCancelled { return }
                        resourceList.setDetailTopReport(report)
                    } else if isNodePods {
                        let pods = try await viewModel.nodePods(for: row)
                        if Task.isCancelled { return }
                        resourceList.setDetailNodePods(pods)
                    } else if isNamespaceInv {
                        let items = try await viewModel.namespaceInventory(for: row)
                        if Task.isCancelled { return }
                        resourceList.setDetailInventory(items, namespace: row.name)
                    } else if isMetrics {
                        let report = try await viewModel.podMetrics(for: row, override: nil)
                        if Task.isCancelled { return }
                        // podMetrics returns scrape failures as an empty error-note report
                        // (it doesn't throw), so don't let a transient failure wipe good
                        // cached metrics already on screen — mirror the catch's !showedCache rule.
                        if !report.document.samples.isEmpty || !showedCache {
                            resourceList.setDetailMetrics(report)
                        }
                    } else if isEvents {
                        let events = try await viewModel.resourceEvents(for: row)
                        if Task.isCancelled { return }
                        resourceList.setDetailEvents(events)
                    } else {
                        let text = try await viewModel.detailText(for: row, section: section)
                        if Task.isCancelled { return }
                        resourceList.setDetailText(text)
                    }
                } catch {
                    if Task.isCancelled { return }
                    // Keep any cached result on screen — a transient refresh failure
                    // shouldn't wipe good data with an error.
                    if !showedCache { resourceList.setDetailText("Error: \(error.localizedDescription)") }
                }
                if !isLive { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Context popup

    private func updateContextPopup() {
        contextPopup.menu?.removeAllItems()
        for ctx in viewModel.contexts {
            let item = NSMenuItem()
            item.attributedTitle = contextTitle(ctx)
            item.representedObject = ctx.name
            contextPopup.menu?.addItem(item)
        }
        // Customize (color / emoji) lives at the bottom of the list — the toolbar
        // swallows right-clicks, so the dropdown is the reliable place for it.
        if !viewModel.contexts.isEmpty {
            contextPopup.menu?.addItem(.separator())
            let customize = NSMenuItem(title: "Customize Current Context…",
                                       action: nil, keyEquivalent: "")
            customize.tag = Self.customizeMenuTag
            contextPopup.menu?.addItem(customize)
        }
        if let selected = viewModel.selectedContext,
           let idx = viewModel.contexts.firstIndex(where: { $0.name == selected }) {
            contextPopup.selectItem(at: idx)
        }
        let color = viewModel.selectedContext.flatMap {
            ContextAppearanceStore.appearance(for: $0).color
        }
        resourceList.setContextBandColor(color)
    }

    private func contextTitle(_ ctx: ClusterContext) -> NSAttributedString {
        let appearance = ContextAppearanceStore.appearance(for: ctx.name)
        let result = NSMutableAttributedString()
        if let emoji = appearance.emoji, !emoji.isEmpty {
            result.append(NSAttributedString(string: emoji + "  ",
                attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        result.append(NSAttributedString(
            string: ctx.displayName,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor]))
        if ctx.isProduction {
            result.append(NSAttributedString(
                string: "  PROD",
                attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                             .foregroundColor: NSColor.systemRed]))
        }
        return result
    }

    @objc func customizeContext(_ sender: Any?) {
        guard let name = viewModel.selectedContext else { return }
        let vc = ContextCustomizeViewController(
            context: name, displayName: viewModel.contextInfo(name)?.displayName ?? name)
        vc.onChange = { [weak self] in self?.updateContextPopup() }
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        // Anchor under the context picker in the toolbar.
        popover.show(relativeTo: contextPopup.bounds, of: contextPopup, preferredEdge: .maxY)
        customizePopover = popover
    }

    @objc private func contextChanged(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == Self.customizeMenuTag {
            updateContextPopup()        // restore the real selection (drop "Customize…")
            customizeContext(nil)
            return
        }
        guard let name = sender.selectedItem?.representedObject as? String,
              name != viewModel.selectedContext else { return }
        Task { await viewModel.selectContext(name) }
    }

    // MARK: - Actions

    @objc func refresh(_ sender: Any?) {
        viewModel.refreshNow()
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func toggleHideSystemNamespaces(_ sender: Any?) {
        hideSystemNamespaces.toggle()
        UserDefaults.standard.set(hideSystemNamespaces, forKey: hideSystemDefaultsKey)
        resourceList.setHideSystemNamespaces(hideSystemNamespaces)
    }

    /// Build the Finder-style Group menu: "None" on top, then this kind's dimensions,
    /// a checkmark on the active choice.
    private func rebuildGroupMenu() {
        groupMenu.removeAllItems()
        let current = resourceList.currentGrouping
        let none = groupMenu.addItem(withTitle: "None", action: #selector(groupMenuPicked(_:)), keyEquivalent: "")
        none.target = self
        none.state = (current == nil) ? .on : .off   // representedObject nil → None (flat)
        let dims = resourceList.availableGroupings
        if !dims.isEmpty { groupMenu.addItem(.separator()) }
        for dim in dims {
            let item = groupMenu.addItem(withTitle: dim.title, action: #selector(groupMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dim.rawValue
            item.state = (dim == current) ? .on : .off
        }
    }

    @objc private func groupMenuPicked(_ sender: NSMenuItem) {
        let dim = (sender.representedObject as? String).flatMap(GroupBy.init(rawValue:))
        resourceList.setGroupBy(dim)   // nil → None/flat
    }

    /// Click the Group island → pop the full menu (None + dimensions) below it.
    @objc private func showGroupMenu(_ sender: NSButton) {
        rebuildGroupMenu()
        groupMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    /// Disable the Group island for kinds that can't be grouped (events, …).
    private func updateGroupItemState() {
        groupButton.isEnabled = !resourceList.availableGroupings.isEmpty
    }

    @objc func toggleBookmarkFilter(_ sender: Any?) {
        bookmarkFilterOn.toggle()
        UserDefaults.standard.set(bookmarkFilterOn, forKey: bookmarkFilterDefaultsKey)
        bookmarkButton.state = bookmarkFilterOn ? .on : .off
        bookmarkButton.image = NSImage(systemSymbolName: bookmarkFilterOn ? "pawprint.fill" : "pawprint",
                                       accessibilityDescription: "Bookmarks")
        applyBookmarkFilter()
    }

    /// Push the current context's pinned namespaces + toggle state into the table
    /// (drives both the filter and the group-header bookmark glyphs).
    private func applyBookmarkFilter() {
        let pinned = viewModel.selectedContext.map { PinnedNamespaces.namespaces(for: $0) } ?? []
        resourceList.setBookmarkFilter(bookmarkFilterOn, pinned: pinned)
    }

    /// Pin/unpin a namespace in the current context and refresh the table live
    /// (from the row menu or a group-header bookmark click).
    private func togglePinnedNamespace(_ namespace: String) {
        guard let ctx = viewModel.selectedContext, !namespace.isEmpty else { return }
        PinnedNamespaces.toggle(namespace, in: ctx)
        applyBookmarkFilter()
    }

    @objc func toggleDetails(_ sender: Any?) {
        showDetails.toggle()
        UserDefaults.standard.set(showDetails, forKey: showDetailsDefaultsKey)
        detailsButton.state = showDetails ? .on : .off
        detailsButton.image = detailsImage(on: showDetails)
        if !showDetails { detailTask?.cancel(); stopLogStream(); resourceList.stopDetailShell() }
        resourceList.setDetailVisible(showDetails)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHideSystemNamespaces(_:)) {
            menuItem.state = hideSystemNamespaces ? .on : .off
        }
        if menuItem.action == #selector(toggleDetails(_:)) {
            menuItem.state = showDetails ? .on : .off
        }
        if menuItem.action == #selector(customizeContext(_:)) {
            return viewModel.selectedContext != nil
        }
        return true
    }

    private func confirmPrimaryAction(_ row: ResourceRow) {
        guard let action = row.kind.primaryAction, let (anchor, rect) = resourceList.rowAnchor(for: row) else { return }
        let res = row.kind.kubectlResource, ns = row.namespace
        // The pod row carries its resolved controlling workload (Deployment/nginx …),
        // or empty for a bare, unmanaged pod.
        let controlledBy = row.cells["controlledBy"].flatMap { $0.isEmpty ? nil : $0 }
        // A delete of a non-controller-managed object is gone for good — treat it as
        // irreversible: stern note, an explicit warning, and Return→Cancel even off prod.
        // A pod is only "safe" when a controller will recreate it; a bare pod is not.
        // A PVC/PV can additionally destroy the backing disk → demand typing the name.
        let barePod = row.kind == .pods && controlledBy == nil
        let irreversibleDelete = action == .delete && (!isRecreatable(row.kind) || barePod)
        let dataLoss = action == .delete && row.kind.requiresTypedDeleteConfirmation
        let note: String
        switch action {
        case .delete where row.kind == .pods:
            note = controlledBy.map { "Managed by \($0) — the pod will be recreated automatically." }
                 ?? "This pod isn’t managed by a controller — deleting it is permanent (it won’t come back)."
        case .delete where dataLoss:
            note = "This may also delete the underlying volume and its data (reclaim policy Delete). "
                 + "It cannot be undone."
        case .delete where irreversibleDelete:
            note = "This \(row.kind.singularName) isn’t managed by a controller — it won’t come back until "
                 + "you re-apply its manifest. Pods depending on it may fail to (re)start."
        case .delete:
            note = "The \(row.kind.singularName) will be deleted."
        case .restart:
            // The consequence depends on the workload's (update) strategy, not a fixed line.
            switch row.cells["rollout"] {
            case "OnDelete":
                note = "Update strategy is OnDelete: this bumps the pod template, but pods are "
                     + "replaced only when you delete them yourself."
            case "Recreate":
                note = "Strategy is Recreate: all pods are terminated at once, then recreated "
                     + "together (brief downtime)."
            default:   // RollingUpdate (k8s default)
                note = "Rolling restart: managed pods are gradually replaced."
            }
        }
        var warning = contextWarning()   // prod warning wins; otherwise flag irreversibility
        if warning == nil, irreversibleDelete { warning = (text: "Cannot be undone", color: .systemOrange) }
        let nsFlag = ns.isEmpty ? "" : " -n \(ns)"   // cluster-scoped kinds (PV) have no namespace
        pauseForConfirm()
        ConfirmPopover.present(
            from: anchor, rect: rect, preferredEdge: .maxY,
            title: "\(action.title) \(row.kind.singularName) “\(row.name)”?",
            detail: confirmDetail(row.namespace),
            warning: warning, note: note,
            confirmTitle: action.title, danger: contextIsDangerous || irreversibleDelete,
            destructive: action == .delete,
            requireTyped: dataLoss ? row.name : nil,
            command: { _ in
                action == .delete
                    ? "kubectl delete \(res) \(row.name)\(nsFlag) --wait=false"
                    : "kubectl rollout restart \(res)/\(row.name)\(nsFlag)"
            },
            onResult: { [weak self] result in
                guard let self else { return }
                self.resumeAfterConfirm()
                if case .confirmed = result { self.viewModel.performPrimaryAction(row) }
            })
    }

    /// Controller-reconciled kinds reappear right after delete; everything else is
    /// gone until its manifest is re-applied — which makes its delete irreversible.
    private func isRecreatable(_ kind: ResourceKind) -> Bool {
        switch kind {
        case .pods, .replicaSets, .endpoints: return true
        default: return false
        }
    }

    private func confirmScale(_ row: ResourceRow) {
        guard row.kind.scalable, let (anchor, rect) = resourceList.rowAnchor(for: row) else { return }
        let current = viewModel.currentReplicas(row)
        let res = row.kind.kubectlResource, ns = row.namespace
        pauseForConfirm()
        ConfirmPopover.present(
            from: anchor, rect: rect, preferredEdge: .maxY,
            title: "Scale \(row.kind.singularName) “\(row.name)”?",
            detail: confirmDetail(row.namespace),
            warning: contextWarning(),
            note: "Currently \(current) replica\(current == 1 ? "" : "s"). Scaling to 0 stops it.",
            confirmTitle: "Scale", danger: contextIsDangerous,
            stepper: .init(label: "Replicas", unit: nil, value: current, min: 0, max: 200, step: 1, presets: [0, 1, 2, 3, 5, 10]),
            command: { n in "kubectl scale \(res)/\(row.name) --replicas=\(n ?? current) -n \(ns)" },
            onResult: { [weak self] result in
                guard let self else { return }
                self.resumeAfterConfirm()
                if case .confirmed(let v) = result, let v { self.viewModel.scale(row, replicas: v) }
            })
    }

    private func confirmRollback(_ row: ResourceRow) {
        guard row.kind.rollbackable, let (anchor, rect) = resourceList.rowAnchor(for: row) else { return }
        let res = row.kind.kubectlResource, ns = row.namespace
        pauseForConfirm()
        ConfirmPopover.present(
            from: anchor, rect: rect, preferredEdge: .maxY,
            title: "Roll back \(row.kind.singularName) “\(row.name)”?",
            detail: confirmDetail(row.namespace),
            warning: contextWarning(),
            note: "0 = previous rollout. See the History tab for revision numbers.",
            confirmTitle: "Roll Back", danger: contextIsDangerous,
            stepper: .init(label: "Revision", unit: nil, value: 0, min: 0, max: 999, step: 1, presets: [0, 1, 2, 3]),
            command: { n in
                let rev = (n ?? 0) > 0 ? " --to-revision=\(n!)" : ""
                return "kubectl rollout undo \(res)/\(row.name)\(rev) -n \(ns)"
            },
            onResult: { [weak self] result in
                guard let self else { return }
                self.resumeAfterConfirm()
                if case .confirmed(let v) = result {
                    self.viewModel.rollback(row, toRevision: (v ?? 0) > 0 ? v : nil)
                }
            })
    }

    /// Pause every polling loop while a confirm popover is open (it's anchored to a
    /// table row, so a refresh would move it), then resume in place with no flash.
    private func pauseForConfirm() { detailTask?.cancel(); viewModel.pause() }
    private func resumeAfterConfirm() { viewModel.resume(); reloadDetail(showLoading: false) }

    private func confirmDetail(_ namespace: String) -> [(String, String, NSColor?)] {
        var rows = [(String, String, NSColor?)]()
        if !namespace.isEmpty { rows.append(("Namespace", namespace, nil)) }
        // Carry the user's per-context customization (emoji + color) into the confirm,
        // so the context reads the same here as in the toolbar / content band.
        let ctx = viewModel.selectedContext ?? ""
        let appearance = ContextAppearanceStore.appearance(for: ctx)
        let name = viewModel.contextInfo(viewModel.selectedContext)?.displayName ?? "—"
        let value = appearance.emoji.map { "\($0)  \(name)" } ?? name
        rows.append(("Context", value, appearance.color))
        return rows
    }

    private func contextWarning() -> (text: String, color: NSColor)? {
        viewModel.contextInfo(viewModel.selectedContext)?.isProduction == true
            ? ("Production cluster", .systemRed) : nil
    }
    private var contextIsDangerous: Bool {
        viewModel.contextInfo(viewModel.selectedContext)?.isProduction ?? false
    }

    // MARK: - Process diagnostics (heap dump / profile)

    private func handleProcessAction(_ action: ProcessAction) {
        guard !action.podName.isEmpty else { return }
        let ns = action.namespace, pod = action.podName
        let (anchor, rect) = resourceList.detailAnchor()
        let shortCmd = String(action.command.prefix(70))
        var detail = confirmDetail(ns)
        detail.append(("PID", action.pid, nil))

        switch action.kind {
        case .heapDump:
            pauseForConfirm()
            ConfirmPopover.present(
                from: anchor, rect: rect, preferredEdge: .maxY,
                title: "Heap dump from “\(pod)”?",
                detail: detail, warning: contextWarning(),
                note: "\(shortCmd)\n\njcmd GC.heap_dump briefly pauses the JVM and writes the heap (can be GBs) into the pod, then copies it out.",
                confirmTitle: "Heap Dump", danger: contextIsDangerous,
                command: { _ in "kubectl exec \(pod) -n \(ns) -- jcmd \(action.pid) GC.heap_dump <dump>.hprof" },
                onResult: { [weak self] result in
                    guard let self else { return }
                    self.resumeAfterConfirm()
                    if case .confirmed = result {
                        self.runDiagnostic("Heap dump", subtitle: "\(ns)/\(pod)") { [vm = self.viewModel] in
                            try await vm.heapDump(namespace: ns, name: pod, pid: action.pid)
                        }
                    }
                })

        case .profile(let preset):
            pauseForConfirm()
            ConfirmPopover.present(
                from: anchor, rect: rect, preferredEdge: .maxY,
                title: "Profile “\(pod)” — \(preset.menuTitle)?",
                detail: detail, warning: contextWarning(),
                note: "async-profiler runs for the chosen duration and adds CPU load.",
                confirmTitle: "Start Profile", danger: contextIsDangerous,
                stepper: .init(label: "Duration", unit: "sec", value: 60, min: 1, max: 3600, step: 10, presets: [30, 60, 120, 300]),
                command: { secs in
                    "kubectl exec \(pod) -n \(ns) -- asprof \(preset.asprofArgs(pid: action.pid, seconds: secs ?? 60, outPath: "<out>.jfr"))"
                },
                onResult: { [weak self] result in
                    guard let self else { return }
                    self.resumeAfterConfirm()
                    if case .confirmed(let secs) = result, let secs {
                        self.runDiagnostic("Profile (\(preset.menuTitle))", subtitle: "\(ns)/\(pod)",
                                           expectedDuration: TimeInterval(secs)) { [vm = self.viewModel] in
                            try await vm.profile(namespace: ns, name: pod, pid: action.pid, preset: preset, seconds: secs)
                        }
                    }
                })
        }
    }

    /// Run a long diagnostic; track the handle so it can be cancelled on window
    /// close, surface it in the Tasks dropdown (progress + elapsed), and show the
    /// result in a notification/popover if the window is still around. `subtitle`
    /// (ns/pod) and `expectedDuration` (profiles only) drive the progress row.
    private func runDiagnostic(_ title: String, subtitle: String, expectedDuration: TimeInterval? = nil,
                               _ op: @escaping () async throws -> URL) {
        var handle: Task<Void, Never>!
        let activityId = activity.begin(title: title, subtitle: subtitle,
                                        expectedDuration: expectedDuration) { handle?.cancel() }
        handle = Task { [weak self] in
            defer {
                self?.diagnosticTasks.remove(handle)
                self?.activity.finish(activityId)
            }
            do {
                let url = try await op()
                // A profile/dump can run for minutes — the user has likely tabbed away,
                // so a completion banner (click → reveal) beats a row-anchored popover.
                // But only when a banner would actually be delivered; otherwise fall back
                // to the popover so the artifact path is never silently lost.
                let deliver = await Notifier.shared.canDeliver()
                guard !Task.isCancelled, let self, self.window != nil else { return }
                if deliver {
                    Notifier.shared.post(title: "\(title) saved",
                                         body: "\(url.lastPathComponent) — click to reveal in Finder",
                                         revealPath: url.path)
                    return
                }
                let (anchor, rect) = self.resourceList.detailAnchor()
                ConfirmPopover.present(
                    from: anchor, rect: rect, preferredEdge: .maxY,
                    title: "\(title) saved", note: url.path,
                    confirmTitle: "Reveal in Finder", cancelTitle: "Close", danger: false,
                    onResult: { result in
                        if case .confirmed = result { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    })
            } catch {
                let deliver = await Notifier.shared.canDeliver()
                guard !Task.isCancelled, let self, self.window != nil else { return }
                if deliver {
                    Notifier.shared.post(title: "\(title) failed",
                                         body: error.localizedDescription, revealPath: nil)
                    return
                }
                let (anchor, rect) = self.resourceList.detailAnchor()
                ConfirmPopover.present(
                    from: anchor, rect: rect, preferredEdge: .maxY,
                    title: "\(title) failed", note: error.localizedDescription,
                    confirmTitle: "OK", cancelTitle: nil, danger: false, onResult: { _ in })
            }
        }
        diagnosticTasks.insert(handle)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        resourceList.setQuery(field.stringValue)
    }

    /// Esc in the toolbar filter clears it and returns focus to the table (so you can
    /// immediately speed-search again).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            resourceList.setQuery("")
            resourceList.focusTable()
            return true
        }
        return false
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Group is its own island (isolated by the spaces around it); the paw merges
        // with the action buttons into one pill on the right.
        [.context, .flexibleSpace, .group, .space, .bookmark, .details, .forwards, .activity, .refresh, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.context, .bookmark, .group, .details, .forwards, .activity, .refresh, .search, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .context:
            let item = NSToolbarItem(itemIdentifier: .context)
            item.label = "Context"
            item.toolTip = "Active cluster context"
            item.view = contextPopup
            return item
        case .bookmark:
            let item = NSToolbarItem(itemIdentifier: .bookmark)
            item.label = "Bookmarks"
            item.toolTip = "Show only pinned namespaces"
            item.view = bookmarkButton
            return item
        case .group:
            // Finder-style Group-by, its own island: a grid button that pops the full
            // None/dimensions menu (NSMenuToolbarItem swallowed the leading "None").
            let item = NSToolbarItem(itemIdentifier: .group)
            item.label = "Group"
            item.toolTip = "Group rows by…"
            item.view = groupButton
            updateGroupItemState()
            return item
        case .details:
            let item = NSToolbarItem(itemIdentifier: .details)
            item.label = "Details"
            item.toolTip = "Show detail panel"
            item.view = detailsButton
            return item
        case .forwards:
            let item = NSToolbarItem(itemIdentifier: .forwards)
            item.label = "Port-forwards"
            item.toolTip = "Active port-forwards"
            item.view = forwardsButton
            return item
        case .activity:
            let item = NSToolbarItem(itemIdentifier: .activity)
            item.label = "Tasks"
            item.toolTip = "Running tasks (heap dump / profile)"
            item.view = activityButton
            return item
        case .refresh:
            let item = NSToolbarItem(itemIdentifier: .refresh)
            item.label = "Refresh"
            item.toolTip = "Refresh (⌘R)"
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
                target: self, action: #selector(refresh(_:)))
            button.bezelStyle = .texturedRounded
            item.view = button
            return item
        case .search:
            let item = NSToolbarItem(itemIdentifier: .search)
            item.label = "Search"
            item.view = searchField
            return item
        default:
            return nil
        }
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    // The Top tab live-polls kubectl every 3s; stop it when the window isn't
    // visible so a backgrounded app doesn't keep hitting the cluster.
    func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    /// Kill every child process and pending task. Must run on BOTH quit paths:
    /// the red close button (windowWillClose) AND Cmd-Q / Quit, which calls
    /// NSApplication.terminate and never fires windowWillClose — so without an
    /// applicationWillTerminate hook, port-forwards/log streams would be orphaned
    /// (reparented to launchd, still holding their bound local ports).
    func shutdown() {
        detailTask?.cancel()
        stopLogStream()
        resourceList.stopDetailShell()
        portForwards.stopAll()
        activity.stopAll()
        diagnosticTasks.forEach { $0.cancel() }
        diagnosticTasks.removeAll()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        detailTask?.cancel()
        stopLogStream()
        resourceList.stopDetailShell()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // Resume without a loading reset so a one-shot detail (node pods / namespace
        // inventory) keeps its rows and selection in place.
        reloadDetail(showLoading: false)
    }
}
