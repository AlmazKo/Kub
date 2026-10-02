import AppKit

/// Bottom detail pane: kind icon + title, a per-kind `DetailSection` switcher, a
/// shared filter field, and one content view at a time (describe text, Top, node
/// pods, namespace inventory, Events, live logs, metrics, shell).
final class DetailPaneView: NSView {
    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let segmented = NSSegmentedControl()
    private let filterField = NSSearchField()
    private let refreshButton = NSButton()
    // Built on an explicit TextKit 1 stack: on macOS 26 a default NSTextView is
    // TextKit 2, whose wrapping ignores the classic container config — so no-wrap
    // "stuck" on. A hand-built TextKit 1 view honours the Wrap Detail Lines setting
    // (applyDetailWrap).
    private let textView: SpeedSearchTextView = {
        let huge = CGFloat.greatestFiniteMagnitude
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: huge, height: huge))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        return SpeedSearchTextView(frame: .zero, textContainer: container)
    }()
    private let scroll = NSScrollView()
    private let topView = TopReportView()
    private let nodePodsView = NodePodsView()
    private let inventoryView = NamespaceInventoryView()
    private let eventsView = EventsTableView()
    private let liveLogView = LiveLogView()
    private let metricsView = MetricsView()
    private let shellView = PodShellView()

    var onSectionChanged: ((DetailSection) -> Void)?
    var onReloadClicked: (() -> Void)?
    var onProcessAction: ((ProcessAction) -> Void)?
    var onOpenPod: ((String, String) -> Void)?
    var onOpenResource: ((ResourceKind, String, String) -> Void)?
    var onReloadMetrics: ((MetricEndpoint) -> Void)?

    private var sections: [DetailSection] = []   // switcher hidden until a row is selected

    var section: DetailSection {
        let i = segmented.selectedSegment
        return (i >= 0 && i < sections.count) ? sections[i] : (sections.first ?? .overview)
    }

    /// Configure which tabs are shown for the current resource kind. The switcher
    /// is hidden when there's only one section (e.g. config maps → Overview only).
    func setSections(_ newSections: [DetailSection]) {
        let desired = newSections.isEmpty ? [.overview] : newSections
        guard desired != sections else { return }
        let previous = section
        sections = desired
        segmented.segmentCount = sections.count
        for (i, s) in sections.enumerated() {
            segmented.setLabel(s.title, forSegment: i)
        }
        segmented.selectedSegment = sections.firstIndex(of: previous) ?? 0
        segmented.isHidden = sections.count <= 1
        updateFilterVisibility()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.contentTintColor = .secondaryLabelColor
        titleIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        titleIcon.setContentHuggingPriority(.required, for: .horizontal)
        titleIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleGroup = NSStackView(views: [titleIcon, titleLabel])
        titleGroup.orientation = .horizontal
        titleGroup.spacing = 5
        titleGroup.alignment = .centerY
        titleGroup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        segmented.segmentStyle = .texturedRounded
        segmented.trackingMode = .selectOne
        segmented.segmentCount = 0
        segmented.isHidden = true   // no tabs until a row is selected
        filterField.isHidden = true
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .regularSquare
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(reloadClicked)
        refreshButton.toolTip = "Reload"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = "Search"
        filterField.controlSize = .small
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.setContentHuggingPriority(.required, for: .horizontal)   // stay compact on the right
        let filterWidth = filterField.widthAnchor.constraint(equalToConstant: 150)
        filterWidth.priority = .defaultHigh   // may shrink on a narrow pane
        filterWidth.isActive = true
        filterField.delegate = self   // Esc in the field clears + returns focus to the content

        // Speed-search (IDEA-style): typing in a focused content view routes to the
        // search field; Esc clears.
        let onType: (String) -> Void = { [weak self] in self?.beginTypeSearch($0) }
        let onEsc: () -> Void = { [weak self] in self?.clearSearch() }
        eventsView.onTypeSearch = onType;   eventsView.onEscape = onEsc
        nodePodsView.onTypeSearch = onType; nodePodsView.onEscape = onEsc
        inventoryView.onTypeSearch = onType; inventoryView.onEscape = onEsc
        textView.onTypeSearch = onType;     textView.onEscape = onEsc

        let header = NSStackView(views: [titleGroup, NSView(), segmented, filterField, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 8, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        (header.arrangedSubviews[1]).setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureTextView()
        NotificationCenter.default.addObserver(forName: .kubWrapDetailTextChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDetailWrap() }
        }

        topView.translatesAutoresizingMaskIntoConstraints = false
        topView.isHidden = true
        topView.onProcessAction = { [weak self] action in self?.onProcessAction?(action) }

        nodePodsView.translatesAutoresizingMaskIntoConstraints = false
        nodePodsView.isHidden = true
        nodePodsView.onOpenPod = { [weak self] ns, name in self?.onOpenPod?(ns, name) }

        inventoryView.translatesAutoresizingMaskIntoConstraints = false
        inventoryView.isHidden = true
        inventoryView.onOpenResource = { [weak self] kind, ns, name in self?.onOpenResource?(kind, ns, name) }

        eventsView.translatesAutoresizingMaskIntoConstraints = false
        eventsView.isHidden = true

        liveLogView.translatesAutoresizingMaskIntoConstraints = false
        liveLogView.isHidden = true

        metricsView.translatesAutoresizingMaskIntoConstraints = false
        metricsView.isHidden = true
        metricsView.onReload = { [weak self] endpoint in self?.onReloadMetrics?(endpoint) }

        shellView.translatesAutoresizingMaskIntoConstraints = false
        shellView.isHidden = true

        addSubview(separator)
        addSubview(header)
        addSubview(scroll)
        addSubview(topView)
        addSubview(nodePodsView)
        addSubview(inventoryView)
        addSubview(eventsView)
        addSubview(liveLogView)
        addSubview(metricsView)
        addSubview(shellView)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            topView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            topView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            topView.topAnchor.constraint(equalTo: scroll.topAnchor),
            topView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            nodePodsView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            nodePodsView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            nodePodsView.topAnchor.constraint(equalTo: scroll.topAnchor),
            nodePodsView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            inventoryView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            inventoryView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            inventoryView.topAnchor.constraint(equalTo: scroll.topAnchor),
            inventoryView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            eventsView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            eventsView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            eventsView.topAnchor.constraint(equalTo: scroll.topAnchor),
            eventsView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            liveLogView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            liveLogView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            liveLogView.topAnchor.constraint(equalTo: scroll.topAnchor),
            liveLogView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            metricsView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            metricsView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            metricsView.topAnchor.constraint(equalTo: scroll.topAnchor),
            metricsView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            shellView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            shellView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            shellView.topAnchor.constraint(equalTo: scroll.topAnchor),
            shellView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        let huge = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: huge, height: huge)

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        applyDetailWrap()   // wrap / no-wrap per Settings.wrapDetailText
    }

    /// Wrap long lines to the pane width, or (default) let them run and scroll
    /// horizontally. The scroll view is constraint-pinned to the pane, so a wide
    /// no-wrap document scrolls without widening the window (a naive no-wrap
    /// document used to make the window jump between tabs).
    private func applyDetailWrap() {
        // On macOS 26 NSTextView is TextKit 2 by default; touching `layoutManager`
        // migrates it to TextKit 1. Do that FIRST — migrating *after* configuring the
        // container recreates the container and undoes the no-wrap settings (which is
        // why wrapping "stuck" on). Then the container reliably controls wrapping.
        _ = textView.layoutManager
        guard let container = textView.textContainer else { return }
        let wrap = Settings.wrapDetailText
        let huge = CGFloat.greatestFiniteMagnitude
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        container.widthTracksTextView = wrap
        container.size = wrap ? NSSize(width: 0, height: huge) : NSSize(width: huge, height: huge)
        scroll.hasHorizontalScroller = !wrap
        textView.layoutManager?.ensureLayout(for: container)
        textView.needsDisplay = true
    }

    // MARK: - API

    /// Title with the resource kind's symbol (nil = no icon, e.g. no selection).
    func setTitle(symbol: String?, _ title: String) {
        if let symbol {
            titleIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            titleIcon.isHidden = false
        } else {
            titleIcon.isHidden = true
        }
        titleLabel.stringValue = title
    }

    func setText(_ text: String) {
        show(.text)
        applyDetailWrap()   // keep wrap/no-wrap current on every render
        switch section {
        case .logs:
            textView.textStorage?.setAttributedString(LogFormatter.format(text))
        case .overview, .health, .containers, .mounts:
            textView.textStorage?.setAttributedString(DescribeFormatter.format(text))
        case .events, .history, .top, .pods, .resources, .metrics, .shell:
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .labelColor
            textView.string = text
        }
        textView.scroll(NSPoint(x: 0, y: 0))
        if !filterField.isHidden { applyTextFind(filterField.stringValue) }   // re-highlight after a re-render
    }

    /// Render a pod's parsed Prometheus metrics as a filterable table.
    func setMetrics(_ report: MetricsReport) {
        show(.metrics)
        metricsView.setReport(report)
    }

    /// Show the interactive shell view for a pod (idempotent — keeps a live session).
    func configureShell(context: String, namespace: String, pod: String, container: String?, isProduction: Bool) {
        show(.shell)
        shellView.configure(context: context, namespace: namespace, pod: pod, container: container, isProduction: isProduction)
    }
    /// Kill the shell's child process (no-op if not running).
    func stopShell() { shellView.stop() }

    /// Render the structured Top report (metrics card + sortable process table).
    func setTopReport(_ report: PodTopReport) {
        show(.top)
        topView.update(report)
    }

    /// Render the pods scheduled on a node as a native table.
    func setNodePods(_ pods: [ResourceRow]) {
        show(.nodePods)
        nodePodsView.setPods(pods)
    }

    /// Render a resource's Events as a native, sortable table.
    func setEvents(_ events: [ResourceRow]) {
        show(.events)
        eventsView.setEvents(events)
    }

    /// Render a namespace's resource entities as a native table.
    func setInventory(_ items: [NamespaceResource], namespace: String) {
        show(.inventory)
        inventoryView.setItems(items, namespace: namespace)
    }

    func setInventoryLoading(_ message: String) {
        show(.inventory)
        inventoryView.showLoading(message)
    }

    func setLoading(_ message: String) {
        switch section {
        case .top:
            show(.top)
            topView.showLoading(message)
        case .pods:
            show(.nodePods)
            nodePodsView.showLoading(message)
        case .metrics:
            show(.metrics)
            metricsView.showLoading(message)
        case .events:
            show(.events)
            eventsView.showLoading(message)
        default:
            show(.text)
            textView.textColor = .secondaryLabelColor
            textView.string = message
        }
    }

    /// Which content view is visible (text / top / nodePods / inventory / events / liveLog / metrics / shell).
    private enum Content { case text, top, nodePods, inventory, events, liveLog, metrics, shell }
    private func show(_ content: Content) {
        scroll.isHidden = content != .text
        topView.isHidden = content != .top
        nodePodsView.isHidden = content != .nodePods
        inventoryView.isHidden = content != .inventory
        eventsView.isHidden = content != .events
        liveLogView.isHidden = content != .liveLog
        metricsView.isHidden = content != .metrics
        shellView.isHidden = content != .shell
    }

    /// Switch to the live-follow log view and clear it for a new stream.
    func startLiveLog() {
        show(.liveLog)
        liveLogView.reset()
    }
    func appendLiveLog(_ lines: [String]) { liveLogView.append(lines) }

    @objc private func segmentChanged() {
        updateFilterVisibility()
        routeFilter(filterField.stringValue)   // carry the query into the new section
        onSectionChanged?(section)
    }

    @objc private func filterChanged() {
        routeFilter(filterField.stringValue)
    }

    /// Route the search text to whatever content is active: filter table rows, or
    /// highlight + scroll matches in the text views. (Logs/Metrics have their own
    /// filter; Shell/Top don't participate.)
    private func routeFilter(_ q: String) {
        switch section {
        case .events: eventsView.setFilter(q)
        case .pods: nodePodsView.setFilter(q)
        case .resources: inventoryView.setFilter(q)
        case .overview, .health, .containers, .mounts, .history:
            textFind = q
            applyTextFind(q)
        case .top, .logs, .metrics, .shell: break
        }
    }

    private var textFind = ""
    /// Highlight every match in the detail text and scroll to the first.
    private func applyTextFind(_ q: String) {
        guard let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let text = storage.string as NSString
        var search = NSRange(location: 0, length: text.length)
        var first: NSRange?
        while search.location < text.length {
            let found = text.range(of: query, options: .caseInsensitive, range: search)
            if found.location == NSNotFound { break }
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: found)
            if first == nil { first = found }
            let next = found.location + max(1, found.length)
            search = NSRange(location: next, length: text.length - next)
        }
        if let first { textView.scrollRangeToVisible(first) }
    }

    /// Hidden for content with its own filter (Logs / Metrics) or none (Shell / Top).
    private func updateFilterVisibility() {
        switch section {
        case .logs, .metrics, .shell, .top: filterField.isHidden = true
        default: filterField.isHidden = false
        }
    }

    /// A printable key hit a focused content view → grow the search and move focus
    /// to the field so the next keystrokes edit it normally.
    private func beginTypeSearch(_ char: String) {
        guard !filterField.isHidden else { return }
        if filterField.stringValue.isEmpty, char == " " { return }   // don't start on a bare space
        filterField.stringValue += char
        routeFilter(filterField.stringValue)
        window?.makeFirstResponder(filterField)
        filterField.currentEditor()?.selectedRange = NSRange(location: (filterField.stringValue as NSString).length, length: 0)
    }

    private func clearSearch() {
        guard !filterField.stringValue.isEmpty else { return }
        filterField.stringValue = ""
        routeFilter("")
    }

    /// Return keyboard focus to the active content (after Esc in the search field).
    private func focusActiveContent() {
        switch section {
        case .events: eventsView.focusTable()
        case .pods: nodePodsView.focusTable()
        case .resources: inventoryView.focusTable()
        case .overview, .health, .containers, .mounts, .history: window?.makeFirstResponder(textView)
        default: break
        }
    }

    @objc private func reloadClicked() {
        onReloadClicked?()
    }
}

// MARK: - Speed-search field (Esc clears + returns focus)

extension DetailPaneView: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === filterField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            clearSearch()
            focusActiveContent()
            return true
        }
        return false
    }
}

// MARK: - Cross-reference links in the Overview

extension DetailPaneView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, url.scheme == "kub",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let kindRaw = q["kind"], let kind = ResourceKind(rawValue: kindRaw), let name = q["name"] else { return false }
        onOpenResource?(kind, q["ns"] ?? "", name)
        return true   // we handled it — don't let the system try to open the URL
    }
}

/// Styles `kubectl logs --all-containers --timestamps --prefix` output:
/// drops the pod name from the `[pod/<pod>/<container>]` prefix (keeps the
/// container, muted), cleans up + tints the RFC3339 timestamp, and renders
/// embedded ANSI color escape codes (SGR) as real text styling.
@MainActor
enum LogFormatter {
    private static let regular = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    static func format(_ raw: String) -> NSAttributedString {
        let containerAttrs: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: NSColor.tertiaryLabelColor]
        let timeAttrs: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: NSColor.systemTeal]

        let result = NSMutableAttributedString()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineSub) in lines.enumerated() {
            var line = String(lineSub)
            if line.hasSuffix("\r") { line.removeLast() }

            // [pod/<pod>/<container>] prefix → keep only the container.
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let inside = line[line.index(after: line.startIndex)..<close]
                let comps = inside.split(separator: "/")
                if comps.count >= 3, comps[0] == "pod" {
                    let container = comps[2...].joined(separator: "/")
                    result.append(NSAttributedString(string: container + "  ", attributes: containerAttrs))
                    line = String(line[line.index(after: close)...])
                    if line.hasPrefix(" ") { line.removeFirst() }
                }
            }

            // kubectl --timestamps RFC3339 prefix → cleaned + tinted (skipped if the
            // line begins with ANSI codes / the app's own timestamp instead).
            if let spaceIdx = line.firstIndex(of: " ") {
                let token = String(line[..<spaceIdx])
                if let pretty = prettyTimestamp(token) {
                    result.append(NSAttributedString(string: pretty + "  ", attributes: timeAttrs))
                    line = String(line[line.index(after: spaceIdx)...])
                }
            }

            appendANSI(line, into: result)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: regular]))
            }
        }
        return result
    }

    /// "2026-06-29T15:37:56.906629674Z" → "2026-06-29 15:37:56" (nil if not a timestamp).
    private static func prettyTimestamp(_ token: String) -> String? {
        guard let first = token.first, first.isNumber,
              let tIdx = token.firstIndex(of: "T") else { return nil }
        let date = token[..<tIdx]
        guard date.contains("-") else { return nil }
        let afterT = token[token.index(after: tIdx)...]
        let time = afterT.prefix { $0 != "." && $0 != "Z" && $0 != "+" }
        guard time.contains(":") else { return nil }
        return "\(date) \(time)"
    }

    // MARK: - ANSI SGR

    /// Parse ANSI escape codes in `text`, emit styled runs, and strip the codes.
    private static func appendANSI(_ text: String, into result: NSMutableAttributedString) {
        var fg: NSColor?
        var bold = false
        var dim = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var color = fg ?? .labelColor
            if dim { color = color.withAlphaComponent(0.6) }
            result.append(NSAttributedString(string: buffer,
                attributes: [.font: bold ? self.bold : regular, .foregroundColor: color]))
            buffer = ""
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2
                while j < chars.count, chars[j].isNumber || chars[j] == ";" { j += 1 }
                if j < chars.count, chars[j].isLetter {
                    if chars[j] == "m" {
                        flush()
                        applySGR(String(chars[(i + 2)..<j]), fg: &fg, bold: &bold, dim: &dim)
                    }
                    // any CSI (SGR or cursor/erase) is consumed and removed
                    i = j + 1
                    continue
                }
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
    }

    private static func applySGR(_ params: String, fg: inout NSColor?, bold: inout Bool, dim: inout Bool) {
        let parts = params.isEmpty ? ["0"] : params.split(separator: ";").map(String.init)
        var k = 0
        while k < parts.count {
            guard let code = Int(parts[k]) else { k += 1; continue }
            switch code {
            case 0: fg = nil; bold = false; dim = false
            case 1: bold = true
            case 2: dim = true
            case 22: bold = false; dim = false
            case 39: fg = nil
            case 30...37, 90...97: fg = ansiColor(code)
            case 38:
                if k + 2 < parts.count, parts[k + 1] == "5", let n = Int(parts[k + 2]) {
                    fg = xterm256(n); k += 2
                } else if k + 4 < parts.count, parts[k + 1] == "2",
                          let r = Int(parts[k + 2]), let g = Int(parts[k + 3]), let b = Int(parts[k + 4]) {
                    fg = readable(NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
                    k += 4
                }
            default: break   // background colors and other attributes are ignored
            }
            k += 1
        }
    }

    private static func ansiColor(_ code: Int) -> NSColor? {
        switch code {
        case 30, 90: return .secondaryLabelColor   // black / bright black → readable gray
        case 31, 91: return .systemRed
        case 32, 92: return .systemGreen
        case 33, 93: return .systemYellow
        case 34, 94: return .systemBlue
        case 35, 95: return .systemPurple
        case 36, 96: return .systemTeal
        case 37, 97: return .labelColor            // white → default text color
        default: return nil
        }
    }

    private static func xterm256(_ n: Int) -> NSColor {
        if n < 16 { return ansiColor(n < 8 ? n + 30 : n + 82) ?? .labelColor }
        if n <= 231 {
            let c = n - 16
            let comp = { (v: Int) -> CGFloat in v == 0 ? 0 : CGFloat(55 + v * 40) / 255 }
            return readable(NSColor(srgbRed: comp(c / 36), green: comp((c % 36) / 6), blue: comp(c % 6), alpha: 1))
        }
        let v = CGFloat(8 + (n - 232) * 10) / 255
        return readable(NSColor(srgbRed: v, green: v, blue: v, alpha: 1))
    }

    private static var isDarkTheme: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Keep an absolute ANSI color (xterm-256 / truecolor) readable against the
    /// current theme's background — logs pick colors for a dark terminal, so cap
    /// brightness in light mode and floor it in dark mode.
    static func readable(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        b = isDarkTheme ? max(b, 0.55) : min(b, 0.6)
        return NSColor(hue: h, saturation: s, brightness: b, alpha: a)
    }
}

/// Renders `kubectl describe` output as colored key–value pairs: keys tinted,
/// section headers bold, values in the default text color. Cross-references
/// (Namespace / Node / Controlled By) are turned into clickable `kub://` links.
@MainActor
enum DescribeFormatter {
    static func format(_ raw: String) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let boldMono = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        // Every key is teal. Top-level sections are bold in the label colour as a
        // structural anchor; nested block names (container/volume nodes) are teal but
        // *not* bold — colour alone marks them, no double emphasis. Values plain.
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.systemTeal]
        let subHeaderAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.systemTeal]
        let sectionAttrs: [NSAttributedString.Key: Any] = [.font: boldMono, .foregroundColor: NSColor.labelColor]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor]

        let namespace = currentNamespace(raw)
        let result = NSMutableAttributedString()
        func add(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: s, attributes: attrs))
        }
        // `describe` is indentation-structured (tabwriter): a field's value starts at
        // a fixed column, and its extra values wrap onto lines indented *to that same
        // column* (a 2nd Label/Annotation/Toleration). Track the current value column
        // so those wrapped lines render plain — even when they are themselves
        // "subkey: value" shaped (e.g. `kubectl.kubernetes.io/restartedAt: 2025-…`).
        var valueCol = 0
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineSub) in lines.enumerated() {
            let line = String(lineSub)
            let indent = String(line.prefix { $0 == " " })
            let content = line.dropFirst(indent.count)

            // Indented to (or past) the current value column → a wrapped continuation
            // of the previous value, not a new key.
            if valueCol > 0, indent.count >= valueCol {
                add(line, valueAttrs)
                if index < lines.count - 1 { add("\n", valueAttrs) }
                continue
            }
            add(indent, valueAttrs)

            if let colon = content.firstIndex(of: ":") {
                let key = String(content[..<colon])
                let afterColon = content[content.index(after: colon)...]
                let spaces = String(afterColon.prefix { $0 == " " })
                let value = String(afterColon.drop { $0 == " " })

                if value.isEmpty {
                    // A header: top-level section (Containers:/Events:…) or a nested
                    // block name (a container/volume name) — bold label colour vs teal, not bold.
                    add(key + ":", indent.isEmpty ? sectionAttrs : subHeaderAttrs)
                } else if afterColon.first == " ", !key.contains("  ") {
                    // A real "key: value": tabwriter always puts a space after the
                    // colon, and a key is a single label (no 2+ space column gap).
                    // This rejects a colon *inside* a value (taint key:effect,
                    // image:tag, host:port, url) and a multi-column table row whose
                    // message happens to contain a colon.
                    valueCol = indent.count + key.count + 1 + spaces.count
                    add(key + ":", keyAttrs)
                    add(spaces, valueAttrs)
                    if let url = linkURL(key: key, value: value, namespace: namespace) {
                        var linkAttrs = valueAttrs
                        linkAttrs[.link] = url
                        add(value, linkAttrs)
                    } else {
                        add(value, valueAttrs)
                    }
                } else {
                    // Value with an embedded colon, or a table/continuation row.
                    add(String(content), valueAttrs)
                }
            } else {
                add(String(content), valueAttrs)
            }
            if index < lines.count - 1 { add("\n", valueAttrs) }
        }
        return result
    }

    /// The resource's own namespace, parsed from the describe output (for
    /// resolving owner-reference links that don't repeat it).
    private static func currentNamespace(_ raw: String) -> String? {
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Namespace:") {
                let ns = t.dropFirst("Namespace:".count).trimmingCharacters(in: .whitespaces)
                return ns.isEmpty ? nil : ns
            }
        }
        return nil
    }

    /// A `kub://open?kind=…&ns=…&name=…` link for the cross-reference fields.
    private static func linkURL(key: String, value: String, namespace: String?) -> URL? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != "<none>" else { return nil }
        switch key.trimmingCharacters(in: .whitespaces) {
        case "Namespace":
            return openURL(kind: .namespaces, namespace: nil, name: v)
        case "Node":
            return openURL(kind: .nodes, namespace: nil, name: String(v.split(separator: "/").first ?? Substring(v)))
        case "Controlled By", "Object":   // owner ref / event involved object: "Kind/name"
            let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = NamespaceInventory.kindByApiKind[parts[0]] else { return nil }
            return openURL(kind: kind, namespace: namespace, name: parts[1])
        case "ConfigMap":   // the Mounts tab's volume/env sources
            return openURL(kind: .configMaps, namespace: namespace, name: v)
        case "Secret":
            return openURL(kind: .secrets, namespace: namespace, name: v)
        case "PVC":
            return openURL(kind: .persistentVolumeClaims, namespace: namespace, name: v)
        default:
            return nil
        }
    }

    private static func openURL(kind: ResourceKind, namespace: String?, name: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "kub"
        comps.host = "open"
        var items = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "name", value: name)]
        if let namespace, !namespace.isEmpty { items.append(URLQueryItem(name: "ns", value: namespace)) }
        comps.queryItems = items
        return comps.url
    }
}
