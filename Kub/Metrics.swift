import Foundation

// MARK: - Model

/// Where a pod exposes its Prometheus metrics (a container port + HTTP path).
struct MetricEndpoint: Sendable, Equatable {
    var port: Int
    var path: String   // always begins with "/"
}

/// One parsed metric line: a fully-qualified series and its value.
struct MetricSample: Sendable {
    let name: String        // family name, e.g. http_requests_total
    let labels: String      // label set rendered as `k="v",…` (empty if none)
    let value: Double       // numeric value for sorting (±Inf / NaN supported)
    let valueText: String   // original token, shown verbatim (no precision loss)
}

/// A parsed `/metrics` document: samples plus per-family HELP/TYPE metadata.
struct MetricsDocument: Sendable {
    var samples: [MetricSample] = []
    var help: [String: String] = [:]
    var type: [String: String] = [:]
}

/// Result of a metrics fetch for the detail pane: what we scraped (endpoint),
/// the parsed document, and an optional note (e.g. discovery failed → ask for a port).
struct MetricsReport: Sendable {
    var endpoint: MetricEndpoint?
    var document: MetricsDocument
    var note: String?
}

// MARK: - Endpoint discovery

/// Prometheus-Operator monitors (from every namespace) + the pod namespace's Services,
/// used to resolve a pod's scrape endpoint authoritatively. Best-effort — empty on clusters without the operator.
struct MetricsSources: Sendable {
    var serviceMonitors: [K8sServiceMonitor] = []
    var podMonitors: [K8sPodMonitor] = []
    var services: [K8sService] = []
}

enum MetricsDiscovery {
    /// A discovered endpoint plus whether we're *confident* it's the metrics port.
    /// Confident endpoints are scraped automatically; guesses are only pre-filled
    /// into the tab's port field so the user can confirm with Load (a wrong guess
    /// could hit a non-HTTP port and stall). Always yields an endpoint to pre-fill.
    struct Guess: Sendable {
        let endpoint: MetricEndpoint
        let confident: Bool
    }

    /// Resolution order: (1) a ServiceMonitor/PodMonitor that targets this pod — the
    /// authoritative source, since it's exactly what Prometheus scrapes (exact port
    /// AND path); (2) `prometheus.io/port` annotation on the pod, then on a Service
    /// that selects it; (3) a container port named *metrics*/*prom*; (4) a best-effort
    /// guess (management/http port → first port → 8080).
    static func discover(pod: K8sPod, sources: MetricsSources) -> Guess {
        let labels = pod.metadata.labels ?? [:]
        let podNamespace = pod.metadata.namespace ?? ""
        let ports = (pod.spec?.containers ?? []).flatMap { $0.ports ?? [] }
        // Services (in the pod's namespace) whose selector picks this pod.
        let frontingServices = sources.services.filter { svc in
            let sel = svc.spec?.selector ?? [:]
            return !sel.isEmpty && isSubset(sel, of: labels)
        }

        // (1a) PodMonitor — selector matches the pod's labels directly. Monitors come
        // from every namespace; `namespaceSelector` decides whether this one applies.
        for pm in sources.podMonitors
        where targets(pm.spec, monitorNamespace: pm.metadata.namespace ?? "", podNamespace)
            && selectorMatches(pm.spec?.selector, labels) {
            for ep in pm.spec?.podMetricsEndpoints ?? [] {
                if let port = resolvePort(ep, containerPorts: ports, servicePorts: nil) {
                    return Guess(endpoint: MetricEndpoint(port: port, path: normalizePath(ep.path)), confident: true)
                }
            }
        }
        // (1b) ServiceMonitor — selector matches a Service that fronts this pod.
        for sm in sources.serviceMonitors
        where targets(sm.spec, monitorNamespace: sm.metadata.namespace ?? "", podNamespace) {
            for svc in frontingServices where selectorMatches(sm.spec?.selector, svc.metadata.labels ?? [:]) {
                for ep in sm.spec?.endpoints ?? [] {
                    if let port = resolvePort(ep, containerPorts: ports, servicePorts: svc.spec?.ports) {
                        return Guess(endpoint: MetricEndpoint(port: port, path: normalizePath(ep.path)), confident: true)
                    }
                }
            }
        }

        // (2) prometheus.io/port annotation — on the pod, else on a fronting Service
        // (the `kubernetes-service-endpoints` scrape convention). A Service's annotated
        // port may be its own port number rather than the container's; map it through.
        let ann = pod.metadata.annotations ?? [:]
        let annPath = normalizePath(ann["prometheus.io/path"])
        if let raw = ann["prometheus.io/port"], let port = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return Guess(endpoint: MetricEndpoint(port: port, path: annPath), confident: true)
        }
        for svc in frontingServices {
            let sann = svc.metadata.annotations ?? [:]
            guard sann["prometheus.io/scrape"] != "false",
                  let raw = sann["prometheus.io/port"], let n = Int(raw.trimmingCharacters(in: .whitespaces)) else { continue }
            var port = n
            if !ports.contains(where: { $0.containerPort == n }),
               let sp = (svc.spec?.ports ?? []).first(where: { $0.port == n }),
               let tp = sp.targetPort?.text, !tp.isEmpty {
                port = Int(tp) ?? ports.first(where: { $0.name == tp })?.containerPort ?? n
            }
            return Guess(endpoint: MetricEndpoint(port: port, path: normalizePath(sann["prometheus.io/path"])), confident: true)
        }
        // (3) A container port explicitly named for metrics.
        if let named = ports.first(where: {
            let n = ($0.name ?? "").lowercased(); return n.contains("metric") || n.contains("prom")
        }), let port = named.containerPort {
            return Guess(endpoint: MetricEndpoint(port: port, path: annPath), confident: true)
        }
        // (4) Guesses (never auto-scraped): apps commonly serve /metrics on their
        // management/http port without declaring it as a "metrics" port.
        let preferred = ["management", "actuator", "admin", "monitor", "http", "web", "api"]
        for key in preferred {
            if let m = ports.first(where: { ($0.name ?? "").lowercased().contains(key) }),
               let port = m.containerPort {
                return Guess(endpoint: MetricEndpoint(port: port, path: "/metrics"), confident: false)
            }
        }
        if let first = ports.compactMap(\.containerPort).first {
            return Guess(endpoint: MetricEndpoint(port: first, path: "/metrics"), confident: false)
        }
        return Guess(endpoint: MetricEndpoint(port: 8080, path: "/metrics"), confident: false)
    }

    /// A monitor selector matches iff it is non-empty and its matchLabels AND
    /// matchExpressions all hold. Empty selectors are no-match (never auto-hijack).
    private static func selectorMatches(_ selector: LabelSelector?, _ labels: [String: String]) -> Bool {
        guard let selector, !selector.isEmpty else { return false }
        return selector.matches(labels)
    }

    /// Does a monitor in `monitorNamespace` select targets in `podNamespace`? No
    /// `namespaceSelector` means the monitor's own namespace (the operator's default).
    private static func targets(_ spec: MonitorSpec?, monitorNamespace: String, _ podNamespace: String) -> Bool {
        spec?.namespaceSelector?.selects(podNamespace, monitorNamespace: monitorNamespace)
            ?? (monitorNamespace == podNamespace)
    }

    private static func isSubset(_ sub: [String: String], of sup: [String: String]) -> Bool {
        sub.allSatisfy { sup[$0.key] == $0.value }
    }

    /// Resolve a monitor endpoint's port to a numeric container port. `targetPort`
    /// wins; otherwise the named `port` is mapped via the Service (SM) or directly
    /// against the pod's container ports (PM).
    private static func resolvePort(_ ep: MonitorEndpoint, containerPorts: [ContainerPort], servicePorts: [ServicePort]?) -> Int? {
        if let tp = ep.targetPort?.text, !tp.isEmpty {
            if let n = Int(tp) { return n }
            if let cp = containerPorts.first(where: { $0.name == tp })?.containerPort { return cp }
        }
        guard let portName = ep.port, !portName.isEmpty else { return nil }
        if let servicePorts, let sp = servicePorts.first(where: { $0.name == portName }) {
            if let tp = sp.targetPort?.text, !tp.isEmpty {
                if let n = Int(tp) { return n }
                if let cp = containerPorts.first(where: { $0.name == tp })?.containerPort { return cp }
            }
            if let p = sp.port { return p }
        }
        return containerPorts.first(where: { $0.name == portName })?.containerPort
    }

    static func normalizePath(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "/metrics" }
        return raw.hasPrefix("/") ? raw : "/" + raw
    }
}

// MARK: - Prometheus text exposition parser

/// Parses the Prometheus text exposition format. Handles `# HELP`/`# TYPE`
/// comments, label sets with quoted values (embedded `}` / `,` / `"`), an
/// optional trailing scrape timestamp, and the `+Inf` / `-Inf` / `NaN` values.
enum PrometheusParser {
    static func parse(_ text: String) -> MetricsDocument {
        var doc = MetricsDocument()
        // Swift fuses "\r\n" into a SINGLE grapheme Character, so a plain "\n" split
        // won't see line breaks in a CRLF document (which some exporters emit).
        // Normalize CRLF — and bare CR — to LF up front. The guard must be at the
        // SCALAR level: `contains("\r")` (Character) is false for a CRLF doc because
        // the CR is fused into the "\r\n" grapheme.
        let normalized = text.unicodeScalars.contains("\r")
            ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            : text
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            // Leading whitespace is not valid before a sample, but tolerate it.
            while let f = line.first, f == " " || f == "\t" { line = line.dropFirst() }
            guard let first = line.first else { continue }
            if first == "#" {
                parseMeta(line, into: &doc)
            } else if let sample = parseSample(line) {
                doc.samples.append(sample)
            }
        }
        return doc
    }

    /// `# HELP <name> <text>` / `# TYPE <name> <type>` (other `#` lines ignored).
    private static func parseMeta(_ line: Substring, into doc: inout MetricsDocument) {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return }   // "#", keyword, name, [rest]
        let name = String(parts[2])
        let rest = parts.count >= 4 ? String(parts[3]) : ""
        switch parts[1] {
        case "HELP": doc.help[name] = unescapeHelp(rest)
        case "TYPE": doc.type[name] = rest
        default: break
        }
    }

    /// `\\` → `\`, `\n` → newline (per the exposition format's HELP escaping).
    private static func unescapeHelp(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "\\": out.append("\\")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `name{labels} value [timestamp]` → a sample (nil if malformed).
    private static func parseSample(_ line: Substring) -> MetricSample? {
        var idx = line.startIndex
        let end = line.endIndex

        // Metric name: up to '{' or whitespace.
        var name = ""
        while idx < end {
            let c = line[idx]
            if c == "{" || c == " " || c == "\t" { break }
            name.append(c)
            idx = line.index(after: idx)
        }
        guard !name.isEmpty else { return nil }

        // Optional label set — scan to the '}' that closes it, honoring quotes.
        var labels = ""
        if idx < end, line[idx] == "{" {
            var j = line.index(after: idx)
            let contentStart = j
            var inString = false
            var escaped = false
            var close: Substring.Index? = nil
            while j < end {
                let c = line[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "}" {
                    close = j
                    break
                }
                j = line.index(after: j)
            }
            guard let close else { return nil }   // unterminated label set
            labels = String(line[contentStart..<close])
            idx = line.index(after: close)
        }

        // Whitespace, then the value token (ignore any trailing timestamp).
        while idx < end, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        var valueText = ""
        while idx < end {
            let c = line[idx]
            if c == " " || c == "\t" { break }
            valueText.append(c)
            idx = line.index(after: idx)
        }
        guard !valueText.isEmpty else { return nil }
        return MetricSample(name: name, labels: labels, value: parseValue(valueText), valueText: valueText)
    }

    static func parseValue(_ token: String) -> Double {
        switch token {
        case "+Inf", "Inf", "+inf", "inf": return .infinity
        case "-Inf", "-inf": return -.infinity
        case "NaN", "Nan", "nan": return .nan
        default: return Double(token) ?? .nan
        }
    }
}
