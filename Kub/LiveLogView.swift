import AppKit

/// Coalesces off-main log lines into batched main-thread flushes, so a chatty
/// `logs -f` doesn't schedule one main-queue hop (or one text append) per line.
final class LogPump: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    private let flush: @MainActor ([String]) -> Void

    init(flush: @escaping @MainActor ([String]) -> Void) { self.flush = flush }

    func push(_ line: String) {
        lock.lock()
        pending.append(line)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let batch = pending; pending.removeAll(); scheduled = false
            lock.unlock()
            MainActor.assumeIsolated { flush(batch) }
        }
    }
}

/// Scroll view that reports user wheel scrolls. Live-scroll notifications don't
/// fire for legacy mouse wheels, so Follow suspension needs the raw event too.
private final class FollowScrollView: NSScrollView {
    var onUserScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?(event)
    }
}

/// Live pod-log follow view: a stream rendered with `LogFormatter`, a filter field
/// that hides non-matching lines, plus pause/resume and clear. Keeps a capped
/// in-memory buffer so the filter and pause can re-render without re-fetching.
final class LiveLogView: NSView {
    private let scroll = FollowScrollView()
    private let textView = NSTextView()
    private let filterField = NSSearchField()
    private let pauseButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private var allLines: [String] = []
    private let maxLines = 50000
    private let trimTo = 40000    // when over maxLines, drop back to this — so the O(n) rebuild stays rare, not per-batch
    private var filter = ""
    private var paused = false
    private var wrap = true
    private var showTime = true
    private var autoScroll = true
    private var needsTrimRebuild = false   // buffer was head-trimmed while the user read scrollback; re-render on Follow resume
    private var displayedLines = 0         // lines currently rendered (bounds the deferred-trim growth)
    private let followCheck = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let followBottomInset: CGFloat = 12   // within this many points of the end still counts as "at the tail"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        filterField.placeholderString = "Filter…"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.sendsSearchStringImmediately = true
        filterField.setContentHuggingPriority(.required, for: .horizontal)   // don't stretch — sit compact on the right
        let filterWidth = filterField.widthAnchor.constraint(equalToConstant: 180)
        filterWidth.priority = .defaultHigh   // may shrink on a narrow pane
        filterWidth.isActive = true

        pauseButton.setButtonType(.pushOnPushOff)
        pauseButton.bezelStyle = .texturedRounded
        pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        pauseButton.imagePosition = .imageOnly
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.toolTip = "Pause / resume"

        let wrapCheck = NSButton(checkboxWithTitle: "Wrap", target: self, action: #selector(toggleWrap(_:)))
        wrapCheck.state = wrap ? .on : .off
        wrapCheck.font = .systemFont(ofSize: 11)
        wrapCheck.setContentHuggingPriority(.required, for: .horizontal)
        let timeCheck = NSButton(checkboxWithTitle: "Time", target: self, action: #selector(toggleTime(_:)))
        timeCheck.state = showTime ? .on : .off
        timeCheck.font = .systemFont(ofSize: 11)
        timeCheck.setContentHuggingPriority(.required, for: .horizontal)
        followCheck.target = self
        followCheck.action = #selector(toggleAutoScroll(_:))
        followCheck.state = autoScroll ? .on : .off
        followCheck.font = .systemFont(ofSize: 11)
        followCheck.toolTip = "Auto-scroll to the newest lines — turns off when you scroll up; re-enable here"
        followCheck.setContentHuggingPriority(.required, for: .horizontal)

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .texturedRounded

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Buttons on the left, then a flexible gap, then the counts and a compact filter.
        let bar = NSStackView(views: [wrapCheck, timeCheck, followCheck, pauseButton, clearButton,
                                      spacer, statusLabel, filterField])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        // Lay out only what's on screen — otherwise scrolling a 5k-line log lays out
        // the whole document on the main thread and janks the whole app.
        textView.layoutManager?.allowsNonContiguousLayout = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The first user scroll off the tail turns Follow off; it comes back only via
        // the checkbox. Live-scroll notifications fire only for user-driven scrolling —
        // not our own scrollToEnd and not a resize — so there are no false toggles.
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollChanged),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollChanged),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        // Legacy mouse wheels don't post live-scroll notifications — so any upward wheel
        // tick suspends Follow immediately, before the next append can yank the view down.
        scroll.onUserScroll = { [weak self] event in
            if event.scrollingDeltaY > 0 { self?.setFollow(false) }
        }

        addSubview(bar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyWrap()
        updateStatus()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Absolute ANSI colors are clamped for the current theme at render time, so
    /// re-render when the theme changes. (Semantic colors adapt on their own.)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    /// Start fresh for a new pod/stream.
    func reset() {
        allLines.removeAll()
        displayedLines = 0
        needsTrimRebuild = false
        textView.textStorage?.setAttributedString(NSAttributedString())
        updateStatus()
    }

    /// Append a batch of streamed lines (called on the main thread via LogPump).
    func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        allLines.append(contentsOf: lines)
        if allLines.count > maxLines {
            allLines.removeFirst(allLines.count - trimTo)   // trim in chunks → rebuild rarely, not per-batch
            if paused { updateStatus(); return }   // don't repaint/jump while paused
            if !autoScroll && displayedLines < maxLines * 2 {
                // The user is reading scrollback — a rebuild resets their position.
                // Keep appending below and defer the re-render until Follow resumes
                // (bounded: past 2× the cap the rebuild happens anyway).
                needsTrimRebuild = true
                appendVisible(lines)
                return
            }
            rebuild()   // dropped from the front — re-render the whole buffer
            return
        }
        guard !paused else { updateStatus(); return }
        appendVisible(lines)
    }

    // MARK: - Rendering

    private func matches(_ line: String) -> Bool {
        filter.isEmpty || line.range(of: filter, options: .caseInsensitive) != nil
    }

    private func appendVisible(_ lines: [String]) {
        let shown = lines.filter(matches)
        if !shown.isEmpty { appendRendered(shown) }
        updateStatus()
    }

    private func appendRendered(_ lines: [String]) {
        guard let storage = textView.textStorage else { return }
        storage.append(LogFormatter.format(lines.map(displayLine).joined(separator: "\n") + "\n"))
        displayedLines += lines.count
        if autoScroll { scrollToBottom() }
    }

    private func rebuild() {
        guard let storage = textView.textStorage else { return }
        let shown = allLines.filter(matches)
        storage.setAttributedString(shown.isEmpty
            ? NSAttributedString()
            : LogFormatter.format(shown.map(displayLine).joined(separator: "\n") + "\n"))
        displayedLines = shown.count
        needsTrimRebuild = false
        if autoScroll { scrollToBottom() }
        updateStatus()
    }

    /// The line as rendered — with or without kubectl's leading `--timestamps` stamp.
    private func displayLine(_ line: String) -> String {
        showTime ? line : stripTimestamp(line)
    }

    private func stripTimestamp(_ line: String) -> String {
        guard let sp = line.firstIndex(of: " ") else { return line }
        let token = line[line.startIndex..<sp]   // RFC3339Nano, e.g. 2026-07-01T10:05:16.123Z
        guard token.count >= 20, token.first?.isNumber == true, token.contains("T"),
              token.hasSuffix("Z") || token.contains("+") else { return line }
        return String(line[line.index(after: sp)...])
    }

    /// Wrap long lines to the view width, or let them run off with a horizontal scroller.
    private func applyWrap() {
        guard let container = textView.textContainer else { return }
        let big = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if wrap {
            scroll.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            let w = scroll.contentSize.width
            if w > 0 {
                container.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
                textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            }
        } else {
            scroll.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = big
        }
    }

    private func updateStatus() {
        statusLabel.stringValue = filter.isEmpty
            ? "\(allLines.count) lines"
            : "\(allLines.filter(matches).count) / \(allLines.count)"
    }

    // MARK: - Follow / scroll tracking

    private func scrollToBottom() { textView.scrollToEndOfDocument(nil) }

    /// The viewport sits at (or within a line of) the end of the document.
    private var isScrolledToBottom: Bool {
        guard let doc = scroll.documentView else { return true }
        return scroll.contentView.bounds.maxY >= doc.frame.height - followBottomInset
    }

    /// User live-scrolled off the tail: suspend Follow (re-enabled only via the checkbox).
    @objc private func liveScrollChanged(_ note: Notification) {
        if !isScrolledToBottom { setFollow(false) }
    }

    /// Flip Follow (auto-scroll) and keep the checkbox in sync.
    private func setFollow(_ on: Bool) {
        guard autoScroll != on else { return }
        autoScroll = on
        followCheck.state = on ? .on : .off
        if on {
            if needsTrimRebuild { rebuild() }   // sync the deferred head-trim (scrolls to the end)
            else { scrollToBottom() }
        }
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        filter = filterField.stringValue
        rebuild()
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: paused ? "Resume" : "Pause")
        if !paused { rebuild() }   // flush lines that arrived while paused
        updateStatus()
    }

    @objc private func toggleWrap(_ sender: NSButton) {
        wrap = sender.state == .on
        applyWrap()
    }

    @objc private func toggleTime(_ sender: NSButton) {
        showTime = sender.state == .on
        rebuild()   // re-render with/without the leading timestamp
    }

    @objc private func toggleAutoScroll(_ sender: NSButton) {
        autoScroll = sender.state == .on
        guard autoScroll else { return }
        if needsTrimRebuild { rebuild() }   // sync the deferred head-trim, then land on the tail
        else { scrollToBottom() }
    }

    @objc private func clearLog() {
        reset()
    }
}
