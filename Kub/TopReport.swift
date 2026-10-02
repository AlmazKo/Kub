import Foundation

/// Parsed pod "Top" detail: per-container resource usage (from `kubectl top pod
/// --containers`) plus an in-container process snapshot (from `top`/`ps`). The
/// process table is column-agnostic because busybox `top`, procps `top`, and the
/// `ps` fallbacks each emit a different header.
struct PodTopReport: Sendable {
    var containers: [ContainerUsage] = []
    /// Shown in place of container usage when `kubectl top` failed (RBAC / no metrics-server).
    var metricsNote: String?
    /// Header metrics from `top` (Mem / CPU / Load average); empty for `ps`.
    var summary: [TopSummary] = []
    var processColumns: [String] = []
    var processes: [[String]] = []
    /// Shown when exec failed or the container had no top/ps.
    var processNote: String?
    /// Structured node metrics derived from the `top` summary (for indicators).
    var node = NodeSnapshot()
    /// Pod-level resource requests (for the usage-bar ticks). 0 = none set.
    var cpuRequestMillis = 0.0
    var memRequestBytes = 0.0
    /// Pod identity, so the process menu can stamp diagnostics with the right target.
    var podNamespace = ""
    var podName = ""

    static let empty = PodTopReport()
}

/// Structured node-level metrics parsed from the `top` summary block, for the
/// indicator panel. Any field may be absent (e.g. `ps` has no summary).
struct NodeSnapshot: Sendable {
    var cpu: CPUBreakdown?
    var mem: MemBreakdown?
    var load: [Double] = []          // 1m, 5m, 15m
    var tasks: TaskCounts?
    var hasIndicators: Bool { cpu != nil || mem != nil || !load.isEmpty }
}

struct CPUBreakdown: Sendable {      // all values are percentages
    var usr = 0.0, sys = 0.0, nic = 0.0, idle = 0.0, io = 0.0, irq = 0.0, sirq = 0.0
    var busy: Double { max(0, min(100, 100 - idle)) }
}

/// Memory in bytes, normalized across `top` flavors — their `used` means different
/// things (see `TopParser.parseMem`). `usedBytes` is everything that isn't free
/// (page cache included); `appBytes` is what processes actually hold (used − cache).
struct MemBreakdown: Sendable {
    var totalBytes = 0.0, usedBytes = 0.0, appBytes = 0.0, freeBytes = 0.0, cacheBytes = 0.0
}

/// procps `Tasks:` / `Threads:` line, or busybox's `running/total` on its load line.
struct TaskCounts: Sendable {
    var total = 0, running = 0
}

struct ContainerUsage: Sendable, Hashable {
    var pod: String
    var container: String
    var cpu: String
    var memory: String
}

struct TopSummary: Sendable, Hashable {
    var label: String
    var value: String
}

/// Pure parsers for the two text blobs that back the Top tab. Kept separate from
/// the UI so the column-splitting logic stays testable and side-effect free.
enum TopParser {
    private static func fields(_ s: Substring) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// `kubectl top pod <name> --containers` →
    /// `POD  NAME  CPU(cores)  MEMORY(bytes)` rows (header skipped).
    static func parseContainers(_ raw: String) -> [ContainerUsage] {
        var result: [ContainerUsage] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let cols = fields(line)
            guard cols.count >= 4, cols[0] != "POD" else { continue }
            result.append(ContainerUsage(pod: cols[0], container: cols[1], cpu: cols[2], memory: cols[3]))
        }
        return result
    }

    /// Parse `top -bn1` / `ps aux` / `ps -ef` output. Returns the leading summary
    /// block (top only), the column headers, and the data rows. The last column
    /// (COMMAND/CMD/ARGS) captures the remainder of the line so commands with
    /// spaces stay intact. Headers seen in the wild:
    ///   procps `top`:  PID USER PR NI VIRT RES SHR S %CPU %MEM TIME+ COMMAND
    ///   busybox `top`: PID PPID USER STAT VSZ %VSZ [CPU] %CPU COMMAND   (no CPU on one core)
    ///   `ps aux`:      USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
    ///   `ps -ef`:      UID PID PPID C STIME TTY TIME CMD
    static func parseProcesses(_ raw: String)
        -> (summary: [TopSummary], columns: [String], rows: [[String]]) {
        // "\r\n" is ONE grapheme, so a split on "\n" never sees a CRLF break — normalize
        // first, checked at the scalar level (see the Prometheus parser for the gotcha).
        let text = raw.unicodeScalars.contains("\r")
            ? raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : raw
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // The header row has a PID column, ends in a command column, and is mostly
        // known column tokens — so prose like "usage: provide PID and COMMAND"
        // can't masquerade as a table.
        var headerIndex: Int?
        for (i, line) in lines.enumerated() {
            let toks = fields(Substring(line)).map { $0.uppercased() }
            guard toks.contains("PID"),
                  let last = toks.last, last == "COMMAND" || last == "CMD" || last == "ARGS"
            else { continue }
            if toks.filter({ Self.knownHeaderTokens.contains($0) }).count >= 3 {
                headerIndex = i
                break
            }
        }

        guard let h = headerIndex else {
            // Not a recognizable table (e.g. "no top/ps in container") — one column.
            let rows = lines
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { [$0] }
            return ([], rows.isEmpty ? [] : ["OUTPUT"], rows)
        }

        let summary = parseSummary(Array(lines[0..<h]))
        let columns = fields(Substring(lines[h]))
        var rows: [[String]] = []
        if h + 1 < lines.count {
            for line in lines[(h + 1)...] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(splitRow(line, columnCount: columns.count))
            }
        }
        return (summary, columns, rows)
    }

    /// Split a row into exactly `columnCount` cells: the first N-1 are
    /// whitespace-delimited tokens, the last cell is the (space-containing) rest.
    static func splitRow(_ line: String, columnCount n: Int) -> [String] {
        guard n > 0 else { return [] }
        var cells: [String] = []
        var rest = Substring(line)
        func dropLeadingSpaces() {
            while let f = rest.first, f == " " || f == "\t" { rest = rest.dropFirst() }
        }
        for _ in 0..<(n - 1) {
            dropLeadingSpaces()
            if rest.isEmpty { break }
            let token = rest.prefix { $0 != " " && $0 != "\t" }
            cells.append(String(token))
            rest = rest[token.endIndex...]
        }
        dropLeadingSpaces()
        // procps pads every row out to the requested width (`-w512`) — drop the tail.
        while let l = rest.last, l == " " || l == "\t" { rest = rest.dropLast() }
        cells.append(String(rest))
        while cells.count < n { cells.append("") }
        return cells
    }

    static let knownHeaderTokens: Set<String> = [
        "PID", "PPID", "USER", "UID", "STAT", "S", "VSZ", "%VSZ", "RSS", "TTY", "TIME", "TIME+",
        "%CPU", "%MEM", "COMMAND", "CMD", "ARGS", "START", "STIME", "C", "NI", "PR", "VIRT", "SHR", "RES", "CPU",
    ]

    // MARK: - Structured node metrics (for indicators)

    /// Derive structured CPU / memory / load from the `top` summary lines so the
    /// detail panel can draw bars. Recognizes busybox and procps `top` layouts;
    /// anything it can't structure simply stays nil (the raw lines aren't lost —
    /// they remain in `summary`).
    static func parseNode(_ summary: [TopSummary]) -> NodeSnapshot {
        var node = NodeSnapshot()
        var perCore: [CPUBreakdown] = []   // "%Cpu0 :" / "CPU0:" rows when top is in per-core mode
        var memLine: (value: String, unitBytes: Double)?
        var swapLineCache = 0.0            // procps ≤ 3.3.9 reports the page cache on its Swap line
        for s in summary {
            let label = s.label.lowercased()
            if label == "cpu" || label == "%cpu(s)" || label == "cpu(s)" {   // "Cpu(s)" = procps 3.2
                node.cpu = parseCPU(s.value)
            } else if label.hasPrefix("cpu") || label.hasPrefix("%cpu") {
                perCore.append(parseCPU(s.value))
            } else if label == "mem" || label.hasSuffix(" mem") {     // "Mem" / "KiB Mem" / "MiB Mem"
                memLine = (s.value, unitBytes(forLabel: label))
            } else if label == "swap" || label.hasSuffix(" swap") {
                swapLineCache = parseSwapLineCache(s.value, defaultUnitBytes: unitBytes(forLabel: label))
            } else if label == "tasks" || label == "threads" {
                node.tasks = parseTasks(s.value)
            }
            // procps keeps the load on its clock line ("top - 10:00:00 up 13:42, 0 users,
            // load average: 5.10, 3.83, 3.83"); busybox gives it a line of its own
            // ("Load average: 5.61 4.08 3.91 1/1738 2480") — so match it anywhere.
            let line = s.label.isEmpty ? s.value : s.label + ": " + s.value
            if let r = line.range(of: "load average:", options: .caseInsensitive) {
                let parsed = parseLoad(line[r.upperBound...])
                node.load = parsed.load
                if let tasks = parsed.tasks { node.tasks = tasks }
            }
        }
        if node.cpu == nil, !perCore.isEmpty { node.cpu = average(perCore) }
        if let m = memLine { node.mem = parseMem(m.value, defaultUnitBytes: m.unitBytes, swapLineCache: swapLineCache) }
        return node
    }

    /// procps ≤ 3.3.9: "KiB Swap: … free.  6352864 cached Mem" (3.2: "… free,  1263772k cached").
    /// procps-ng's "… avail Mem" in the same place is NOT cache — only "cached" counts.
    private static func parseSwapLineCache(_ value: String, defaultUnitBytes: Double) -> Double {
        let toks = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
        guard let i = toks.firstIndex(where: { $0.lowercased() == "cached" }), i > 0 else { return 0 }
        return bytesValue(toks[i - 1], defaultUnitBytes: defaultUnitBytes) ?? 0
    }

    private static func average(_ cores: [CPUBreakdown]) -> CPUBreakdown {
        var avg = CPUBreakdown()
        let fields: [WritableKeyPath<CPUBreakdown, Double>] = [\.usr, \.sys, \.nic, \.idle, \.io, \.irq, \.sirq]
        for f in fields {
            avg[keyPath: f] = cores.reduce(0) { $0 + $1[keyPath: f] } / Double(cores.count)
        }
        return avg
    }

    private static func unitBytes(forLabel label: String) -> Double {
        if label.hasPrefix("gib") { return 1024 * 1024 * 1024 }
        if label.hasPrefix("mib") { return 1024 * 1024 }
        if label.hasPrefix("kib") { return 1024 }
        return 1024   // busybox "Mem" values carry an explicit K suffix anyway
    }

    /// "64% usr 0% sys 34% idle …" (busybox) or "64.0 us, 0.0 sy, 34.0 id …" (procps).
    private static func parseCPU(_ value: String) -> CPUBreakdown {
        var cpu = CPUBreakdown()
        let toks = value.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "%", with: "% ")   // procps 3.2 glues them: "0.3%us"
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var i = 0
        while i + 1 < toks.count {
            let digits = toks[i].filter { $0.isNumber || $0 == "." }
            guard let num = Double(digits) else { i += 1; continue }
            assignCPU(&cpu, name: toks[i + 1].lowercased(), value: num)
            i += 2
        }
        return cpu
    }

    private static func assignCPU(_ cpu: inout CPUBreakdown, name: String, value: Double) {
        if name.hasPrefix("sirq") || name == "si" { cpu.sirq = value }
        else if name.hasPrefix("irq") || name == "hi" { cpu.irq = value }
        else if name.hasPrefix("us") { cpu.usr = value }
        else if name.hasPrefix("sy") { cpu.sys = value }
        else if name.hasPrefix("ni") { cpu.nic = value }
        else if name.hasPrefix("id") { cpu.idle = value }
        else if name.hasPrefix("io") || name.hasPrefix("wa") { cpu.io = value }
        // "st" (steal) intentionally ignored
    }

    /// busybox: "7605352K used, 519072K free, 21100K shrd, 902720K buff, 2838432K cached"
    /// — no total, and `used` = MemTotal − MemFree, i.e. it *includes* buff+cached.
    /// procps-ng "MiB Mem :": "15990.3 total, 1234.5 free, 4321.0 used, 10434.8 buff/cache"
    /// — `used` *excludes* buff/cache (procps-ng 4 even computes it as total − available,
    /// so no arithmetic identity holds exactly). Old procps (≤ 3.3.9, "buffers") has an
    /// inclusive `used`, with Cached on the Swap line (`swapLineCache`). So the
    /// `buff/cache` label decides; arithmetic only breaks ties for unknown layouts.
    private static func parseMem(_ value: String, defaultUnitBytes: Double, swapLineCache: Double = 0) -> MemBreakdown {
        var used = 0.0, free = 0.0, total = 0.0, cache = swapLineCache
        var hasTotal = false, usedExcludesCache = false
        for part in value.split(separator: ",") {
            let toks = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = toks.first else { continue }
            guard let bytes = bytesValue(first, defaultUnitBytes: defaultUnitBytes) else { continue }
            let name = toks.dropFirst().joined(separator: " ").lowercased()
            if name.contains("used") { used = bytes }
            else if name.contains("free") { free = bytes }
            else if name.contains("total") { total = bytes; hasTotal = true }
            else if name.contains("cache") || name.contains("buff") {   // "buff" + "cached" / "buff/cache" / "buffers"
                cache += bytes
                if name == "buff/cache" { usedExcludesCache = true }
            }
        }
        let usedIncludesCache = usedExcludesCache ? false
            : hasTotal ? abs(used + free - total) <= abs(used + free + cache - total) : true
        var mem = MemBreakdown()
        mem.totalBytes = hasTotal ? total : used + free
        mem.freeBytes = free
        mem.cacheBytes = cache
        mem.usedBytes = usedIncludesCache ? used : used + cache
        mem.appBytes = usedIncludesCache ? max(0, used - cache) : used
        return mem
    }

    /// Parse a number with an optional K/M/G/T suffix (always binary — top's K is KiB)
    /// into bytes; bare numbers use `defaultUnitBytes`.
    private static func bytesValue(_ token: String, defaultUnitBytes: Double) -> Double? {
        var s = token
        var unit = defaultUnitBytes
        if let last = s.last, last.isLetter {
            switch Character(last.lowercased()) {
            case "k": unit = 1024
            case "m": unit = 1024 * 1024
            case "g": unit = 1024 * 1024 * 1024
            case "t": unit = 1024 * 1024 * 1024 * 1024
            default: return nil
            }
            s.removeLast()
        }
        guard let v = Double(s) else { return nil }
        return v * unit
    }

    /// The tail after "load average:" — procps "5.10, 3.83, 3.83"; busybox
    /// "12.64 12.11 12.32 20/982 48096" (+ running/total tasks and the last pid).
    private static func parseLoad(_ text: Substring) -> (load: [Double], tasks: TaskCounts?) {
        var loads: [Double] = []
        var tasks: TaskCounts?
        for tok in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }) {
            if loads.count < 3, let d = Double(tok) {
                loads.append(d)
            } else if tok.contains("/") {
                let p = tok.split(separator: "/")
                if p.count == 2, let r = Int(p[0]), let t = Int(p[1]) { tasks = TaskCounts(total: t, running: r) }
            }
        }
        return (loads, tasks)
    }

    /// procps "12 total,   1 running,  11 sleeping,   0 stopped,   0 zombie".
    private static func parseTasks(_ value: String) -> TaskCounts {
        var tasks = TaskCounts()
        for part in value.split(separator: ",") {
            let toks = part.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard toks.count >= 2, let n = Int(toks[0]) else { continue }
            if toks[1] == "total" { tasks.total = n } else if toks[1] == "running" { tasks.running = n }
        }
        return tasks
    }

    private static func parseSummary(_ lines: [String]) -> [TopSummary] {
        var out: [TopSummary] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            // procps' clock line "top - 10:00:00 up …" would split inside the time.
            if t.hasPrefix("top - ") {
                out.append(TopSummary(label: "top", value: String(t.dropFirst(6))))
            } else if let colon = t.firstIndex(of: ":") {
                out.append(TopSummary(
                    label: String(t[..<colon]).trimmingCharacters(in: .whitespaces),
                    value: String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(TopSummary(label: "", value: t))
            }
        }
        return out
    }
}
