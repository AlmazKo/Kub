import AppKit

/// A thin rounded usage bar drawn from one or more colored segments laid end to
/// end over a muted track. Fractions are 0…1 of the full width.
final class MetricBarView: NSView {
    struct Segment { var fraction: Double; var color: NSColor }
    var segments: [Segment] = [] { didSet { needsDisplay = true } }
    /// Optional tick (0…1) — e.g. the requested-resource level on a usage bar.
    var marker: Double? { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        track.addClip()   // round the filled segments' ends
        var x: CGFloat = 0
        for seg in segments {
            let w = bounds.width * CGFloat(max(0, min(1, seg.fraction)))
            guard w > 0 else { continue }
            seg.color.setFill()
            NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
            x += w
        }
        if let m = marker {
            let mx = bounds.width * CGFloat(max(0, min(1, m)))
            let clamped = min(max(mx - 1, 0), bounds.width - 2)
            NSColor.labelColor.setFill()
            NSRect(x: clamped, y: 0, width: 2, height: bounds.height).fill()
        }
    }
}

/// The indicator panel above the process table: per-container CPU/MEM (share of
/// node), and node CPU / memory / load from the `top` header — each as a labeled
/// bar. Falls back to muted notes when metrics or exec are unavailable.
final class TopSummaryView: NSView {
    private let stack = NSStackView()
    private static let captionWidth: CGFloat = 84
    private static let barWidth: CGFloat = 200

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func showLoading(_ message: String) {
        clear()
        addNote(message)
    }

    func update(_ report: PodTopReport) {
        clear()

        // Pod containers (kubectl top pod --containers), each as CPU + Mem usage
        // bars with a tick marking the requested amount (pod-level requests).
        if let note = report.metricsNote {
            addHeader("RESOURCE USAGE")
            addNote(note)
        } else if !report.containers.isEmpty {
            addHeader("RESOURCE USAGE")
            for c in report.containers {
                let cpuUsage = Quantity.cpuMillicores(c.cpu) ?? 0
                let memUsage = Quantity.memoryBytes(c.memory) ?? 0
                let cpuReq = report.cpuRequestMillis
                let memReq = report.memRequestBytes
                addRow(caption: c.container,
                       bar: Self.usageBar(usage: cpuUsage, request: cpuReq),
                       value: "CPU " + Self.cpuCoresValue(cpuUsage) + Self.reqSuffix(Self.cpuCoresValue(cpuReq), has: cpuReq > 0),
                       tooltip: cpuReq > 0 ? "requested \(Self.cpuCoresValue(cpuReq))" : "no CPU request set")
                addRow(caption: "",
                       bar: Self.usageBar(usage: memUsage, request: memReq),
                       value: "Mem " + Self.bytes(memUsage) + Self.reqSuffix(Self.bytes(memReq), has: memReq > 0),
                       tooltip: memReq > 0 ? "requested \(Self.bytes(memReq))" : "no memory request set")
            }
        }

        // Node CPU / memory / load (top header).
        let node = report.node
        if node.hasIndicators {
            addSpacer()
            addHeader("NODE")

            if let cpu = node.cpu {
                let bar = MetricBarView()
                bar.segments = [
                    .init(fraction: cpu.usr / 100, color: .systemGreen),
                    .init(fraction: (cpu.sys + cpu.nic) / 100, color: .systemOrange),
                    .init(fraction: (cpu.io + cpu.irq + cpu.sirq) / 100, color: .systemRed),
                ]
                addRow(caption: "CPU", bar: bar, value: "\(Int(cpu.busy.rounded()))% busy",
                       valueColor: Self.level(cpu.busy, warn: 75, crit: 90),
                       tooltip: "usr \(Self.pct(cpu.usr)) · sys \(Self.pct(cpu.sys)) · io \(Self.pct(cpu.io)) · idle \(Self.pct(cpu.idle))")
            }

            if let mem = node.mem, mem.totalBytes > 0 {
                let app = max(0, mem.usedBytes - mem.cacheBytes)
                let bar = MetricBarView()
                bar.segments = [
                    .init(fraction: app / mem.totalBytes, color: .systemBlue),
                    .init(fraction: mem.cacheBytes / mem.totalBytes,
                          color: NSColor.systemBlue.withAlphaComponent(0.3)),
                ]
                let pct = mem.usedBytes / mem.totalBytes * 100
                addRow(caption: "Mem", bar: bar,
                       value: "\(Self.bytes(mem.usedBytes)) / \(Self.bytes(mem.totalBytes))  \(Int(pct.rounded()))%",
                       valueColor: Self.level(pct, warn: 80, crit: 92),
                       tooltip: "used \(Self.bytes(mem.usedBytes)) · cache \(Self.bytes(mem.cacheBytes)) · free \(Self.bytes(mem.freeBytes))")
            }

            if !node.load.isEmpty {
                let text = node.load.map { String(format: "%.2f", $0) }.joined(separator: "   ")
                addRow(caption: "Load", bar: nil, value: text,
                       tooltip: "load average · 1 / 5 / 15 min")
            }
        }

        // Exec failure / "no top/ps" — surface here since the table is empty then.
        if let note = report.processNote, report.processes.isEmpty {
            addSpacer()
            addHeader("PROCESSES")
            addNote(note)
        }
    }

    // MARK: - Row builders

    private func clear() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func pin(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    private func addHeader(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 9, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        pin(l)
    }

    private func addNote(_ text: String) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin(l)
    }

    private func addSpacer() {
        let s = NSView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.heightAnchor.constraint(equalToConstant: 3).isActive = true
        pin(s)
    }

    private func addRow(caption: String, bar: MetricBarView?, value: String,
                        valueColor: NSColor = .labelColor, tooltip: String? = nil) {
        let cap = NSTextField(labelWithString: caption)
        cap.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cap.textColor = .secondaryLabelColor
        cap.lineBreakMode = .byTruncatingTail
        cap.toolTip = caption.isEmpty ? nil : caption
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.widthAnchor.constraint(equalToConstant: Self.captionWidth).isActive = true

        // Fixed-width bar slot (an empty placeholder keeps the value column
        // aligned on bar-less rows like Load).
        let slot = bar ?? NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.widthAnchor.constraint(equalToConstant: Self.barWidth).isActive = true
        if let bar { bar.heightAnchor.constraint(equalToConstant: 8).isActive = true }

        let val = NSTextField(labelWithString: value)
        val.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        val.textColor = valueColor
        val.alignment = .left
        val.lineBreakMode = .byTruncatingTail
        val.setContentHuggingPriority(.required, for: .horizontal)
        // Long values must not widen the resizable window.
        val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        val.translatesAutoresizingMaskIntoConstraints = false

        // Trailing flexible spacer absorbs the rest so the bar stays fixed-width
        // and the content stays left-packed.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [cap, slot, val, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.toolTip = tooltip
        pin(row)
    }

    /// A usage bar (green within request, orange over, blue if no request) with a
    /// tick at the requested level. Scaled so both usage and request fit.
    private static func usageBar(usage: Double, request: Double) -> MetricBarView {
        let ref = max(usage, request, 0.0001)
        let bar = MetricBarView()
        let color: NSColor = request <= 0 ? .systemBlue : (usage > request ? .systemOrange : .systemGreen)
        bar.segments = [.init(fraction: usage / ref, color: color)]
        if request > 0 { bar.marker = request / ref }
        return bar
    }

    private static func cpuCoresValue(_ millis: Double) -> String { String(format: "%.2fc", millis / 1000) }

    private static func reqSuffix(_ text: String, has: Bool) -> String { has ? " / \(text)" : "" }

    // MARK: - Formatting

    static func bytes(_ b: Double) -> String {
        let gib = 1024.0 * 1024 * 1024, mib = 1024.0 * 1024
        if b >= gib { return String(format: "%.1f GiB", b / gib) }
        if b >= mib { return String(format: "%.0f MiB", b / mib) }
        return String(format: "%.0f KiB", b / 1024)
    }

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    private static func level(_ v: Double, warn: Double, crit: Double) -> NSColor {
        if v >= crit { return .systemRed }
        if v >= warn { return .systemOrange }
        return .labelColor
    }
}
