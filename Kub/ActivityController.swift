import AppKit

/// Tracks long-running diagnostics (heap dump / profile) and shows them in a
/// toolbar dropdown with a progress bar + elapsed time, mirroring the port-forward
/// sessions popover. Profiles have a known duration (determinate bar); heap dumps
/// don't (indeterminate). Stopping a row cancels the client-side wait — the in-pod
/// command may keep running to completion, but we stop tracking it.
@MainActor
final class ActivityController: NSObject, NSPopoverDelegate {
    private final class Item {
        let id: Int
        let title: String              // "Profile (CPU)"
        let subtitle: String           // "ns/pod"
        let startedAt: Date
        let expectedDuration: TimeInterval?   // nil → indeterminate
        let cancel: () -> Void
        weak var bar: NSProgressIndicator?
        weak var elapsedLabel: NSTextField?
        init(id: Int, title: String, subtitle: String, startedAt: Date,
             expectedDuration: TimeInterval?, cancel: @escaping () -> Void) {
            self.id = id; self.title = title; self.subtitle = subtitle
            self.startedAt = startedAt; self.expectedDuration = expectedDuration; self.cancel = cancel
        }
    }

    private var items: [Item] = []
    private var nextId = 0
    private let popover = NSPopover()
    private var ticker: Timer?
    private let now: () -> Date

    /// Fired with the active task count (for the toolbar badge).
    var onCountChanged: ((Int) -> Void)?
    var count: Int { items.count }

    /// `clock` is injectable so elapsed time is testable; defaults to the wall clock.
    init(clock: @escaping () -> Date = { Date() }) {
        self.now = clock
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    // MARK: - Lifecycle

    /// Register a new activity; returns an id to `finish(_:)` when it completes.
    @discardableResult
    func begin(title: String, subtitle: String, expectedDuration: TimeInterval?,
               cancel: @escaping () -> Void) -> Int {
        let id = nextId; nextId += 1
        items.append(Item(id: id, title: title, subtitle: subtitle, startedAt: now(),
                          expectedDuration: expectedDuration, cancel: cancel))
        onCountChanged?(items.count)
        rebuildIfShown()
        return id
    }

    /// Mark an activity done (no-op if already removed, e.g. the user stopped it).
    func finish(_ id: Int) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: idx)
        onCountChanged?(items.count)
        if items.isEmpty { popover.performClose(nil) } else { rebuildIfShown() }
    }

    /// Cancel every activity's client-side wait and clear the list (window teardown).
    func stopAll() {
        items.forEach { $0.cancel() }
        items.removeAll()
        onCountChanged?(0)
        stopTicker()
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: - Popover

    func show(anchor: NSView, rect: NSRect) {
        rebuild()
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        startTicker()
    }

    func popoverDidClose(_ notification: Notification) { stopTicker() }

    private func rebuildIfShown() { if popover.isShown { rebuild() } }

    private func rebuild() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No active tasks.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(empty)
        } else {
            items.forEach { stack.addArrangedSubview(row(for: $0)) }
        }
        setContent(stack, width: 320)
        refresh()   // fill in the freshly-built bars/labels immediately
    }

    private func row(for item: Item) -> NSView {
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let elapsed = NSTextField(labelWithString: "")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsed.textColor = .secondaryLabelColor
        elapsed.alignment = .right
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        item.elapsedLabel = elapsed

        let stop = NSButton()
        stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
        stop.imagePosition = .imageOnly
        stop.isBordered = false
        stop.bezelStyle = .regularSquare
        stop.contentTintColor = .systemRed
        stop.target = self
        stop.action = #selector(stopItem(_:))
        stop.tag = item.id
        stop.toolTip = "Stop tracking (the in-pod command may keep running)"

        let topRow = NSStackView(views: [title, elapsed, stop])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = (item.expectedDuration == nil)
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        item.bar = bar

        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let col = NSStackView(views: [topRow, bar, subtitle])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.translatesAutoresizingMaskIntoConstraints = false
        col.widthAnchor.constraint(equalToConstant: 296).isActive = true
        topRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    @objc private func stopItem(_ sender: NSButton) {
        guard let item = items.first(where: { $0.id == sender.tag }) else { return }
        item.cancel()
        finish(item.id)
    }

    // MARK: - Ticking

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    /// Update every visible row's bar + elapsed label from wall-clock time.
    private func refresh() {
        let t = now()
        for item in items {
            let elapsed = t.timeIntervalSince(item.startedAt)
            if let expected = item.expectedDuration, expected > 0 {
                // Cap below 100% until finish() removes the row (the op runs a bit
                // past the profile duration for upload/copy-out).
                item.bar?.isIndeterminate = false
                item.bar?.doubleValue = min(elapsed / expected, 0.98)
                item.elapsedLabel?.stringValue = "\(Self.mmss(elapsed)) / \(Self.mmss(expected))"
            } else {
                if item.bar?.isIndeterminate == true { item.bar?.startAnimation(nil) }
                item.elapsedLabel?.stringValue = Self.mmss(elapsed)
            }
        }
    }

    private static func mmss(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Popover content sizing (mirrors PortForwardController)

    private func setContent(_ content: NSStackView, width: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: width, height: container.fittingSize.height)
        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc
    }
}
