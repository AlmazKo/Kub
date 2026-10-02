import Foundation

/// Owns cluster state and drives polling. Everything here runs on the main
/// actor; kubectl calls hop off-main via `KubeService`, so the UI never blocks.
/// `activity` explains *why* a load is in progress so a slow cluster reads as
/// "working on X", never as a frozen window.
@MainActor
final class ClusterViewModel {
    private let service: any KubeService

    private(set) var contexts: [ClusterContext] = []
    private(set) var currentContext: String?
    private(set) var selectedContext: String?
    private(set) var selectedKind: ResourceKind = ResourceKindStore.enabledKinds.first ?? .pods
    private(set) var rows: [ResourceRow] = []
    private(set) var isLoading = false
    private(set) var activity: String?
    private(set) var lastError: String?
    /// Per-kind element counts for the sidebar (from cache; populated as kinds load).
    private(set) var kindCounts: [ResourceKind: Int] = [:]

    /// "Unread" events: how many events are new since the Events tab was last viewed
    /// (per context). Shown in the sidebar as `+N`, and 0 while Events is the visible
    /// kind. `seenEventKeys` is the baseline of event identities considered read.
    private(set) var unreadEvents = 0
    private var seenEventKeys: [String: Set<String>] = [:]

    // All in-flight kubectl commands (they run in parallel) — for the bottom bar.
    private var inflight: [(id: Int, command: String)] = []
    private var inflightCounter = 0

    /// Bottom-bar text: the most recent in-flight command + how many run alongside it.
    var statusLine: String {
        guard let last = inflight.last else { return "" }
        return inflight.count == 1 ? last.command : "\(last.command)   +\(inflight.count - 1) more"
    }

    var onContextsChanged: (() -> Void)?
    var onKindChanged: (() -> Void)?
    var onResourcesChanged: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onCountsChanged: (() -> Void)?

    private struct Cached { let rows: [ResourceRow]; let at: Date }
    /// Per-context cache so switching contexts (and kinds) shows data instantly,
    /// then refreshes in the background. Entries older than `cacheTTL` are reloaded.
    private var rowCache: [String: [ResourceKind: Cached]] = [:]   // context → kind → rows
    private var countCache: [String: [ResourceKind: Int]] = [:]    // context → kind → count
    private let cacheTTL: TimeInterval = 300                       // 5 minutes

    /// Per-context node-name → architecture map, joined onto pod rows (pods carry no
    /// arch of their own). Refreshed on its own ~60s cadence so it never rides the 5s
    /// pod poll. Keyed by context, so a switch never reads another context's arch.
    private struct ArchCache { let map: [String: String]; let at: Date }
    private var nodeArchCache: [String: ArchCache] = [:]
    private let nodeArchTTL: TimeInterval = 60
    /// Contexts with a `get nodes` arch fetch already in flight (see scheduleArchJoin).
    private var archJoinInFlight: Set<String> = []

    private func cachedRows(_ context: String, _ kind: ResourceKind) -> [ResourceRow]? {
        guard let entry = rowCache[context]?[kind], Date().timeIntervalSince(entry.at) < cacheTTL
        else { return nil }
        return entry.rows
    }

    private func storeRows(_ rows: [ResourceRow], context: String, kind: ResourceKind) {
        rowCache[context, default: [:]][kind] = Cached(rows: rows, at: Date())
    }

    /// Generic detail cache — same 5-min TTL as the tables, keyed by
    /// (context, kind, namespace, name, section). Reopening a detail (or switching
    /// a tab) shows the last result instantly; the visible pane still refreshes it.
    private struct DetailEntry { let value: Any; let at: Date }
    private var detailCache: [String: DetailEntry] = [:]

    /// Key must use the context the fetch *ran in* (captured at its start), not
    /// `selectedContext` at store time — else a context switch mid-fetch would file
    /// one context's detail under another's key.
    private func detailKey(_ context: String, _ row: ResourceRow, _ suffix: String) -> String {
        "\(context)|\(row.kind.rawValue)|\(row.namespace)|\(row.name)|\(suffix)"
    }
    private func cachedDetail<T>(_ key: String) -> T? {
        guard let e = detailCache[key], Date().timeIntervalSince(e.at) < cacheTTL else { return nil }
        return e.value as? T
    }
    private func storeDetail(_ key: String, _ value: Any) {
        detailCache[key] = DetailEntry(value: value, at: Date())
        guard detailCache.count > 300 else { return }
        // Hard cap: drop expired entries, then — if still over — evict oldest first.
        // (Within the 5-min window every entry is fresh, so the expired filter alone
        // wouldn't bound anything.)
        let cutoff = Date().addingTimeInterval(-cacheTTL)
        detailCache = detailCache.filter { $0.value.at > cutoff }
        if detailCache.count > 300 {
            let oldest = detailCache.sorted { $0.value.at < $1.value.at }.prefix(detailCache.count - 300)
            for k in oldest.map(\.key) { detailCache.removeValue(forKey: k) }
        }
    }

    // Synchronous cache reads for the detail pane (show instantly, then refresh).
    func cachedDetailText(for row: ResourceRow, section: DetailSection) -> String? {
        cachedDetail(detailKey(selectedContext ?? "", row, "text.\(section.rawValue)"))
    }
    func cachedTop(for row: ResourceRow) -> PodTopReport? { cachedDetail(detailKey(selectedContext ?? "", row, "top")) }
    func cachedNodePods(for row: ResourceRow) -> [ResourceRow]? { cachedDetail(detailKey(selectedContext ?? "", row, "nodepods")) }
    func cachedResourceEvents(for row: ResourceRow) -> [ResourceRow]? { cachedDetail(detailKey(selectedContext ?? "", row, "events")) }
    func cachedInventory(for row: ResourceRow) -> [NamespaceResource]? { cachedDetail(detailKey(selectedContext ?? "", row, "inventory")) }
    func cachedMetrics(for row: ResourceRow) -> MetricsReport? { cachedDetail(detailKey(selectedContext ?? "", row, "metrics")) }

    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: UInt64 = 5_000_000_000 // 5s — the visible kind
    private var countsTask: Task<Void, Never>?
    private let countsInterval: UInt64 = 60_000_000_000 // 60s — sidebar counts of other kinds

    init(service: any KubeService) {
        self.service = service
    }

    func contextInfo(_ name: String?) -> ClusterContext? {
        guard let name else { return nil }
        return contexts.first { $0.name == name }
    }

    // MARK: - Lifecycle

    func start() {
        Task { await loadContexts() }
    }

    func loadContexts() async {
        let cmd = beginCommand("kubectl config view -o json")
        beginActivity("Loading contexts…")
        defer { endActivity(); endCommand(cmd) }
        do {
            let (list, current) = try await service.contexts()
            contexts = list
            currentContext = current
            lastError = nil
            onContextsChanged?()
            if selectedContext == nil, let initial = current ?? list.first?.name {
                await selectContext(initial)
            }
        } catch {
            setError(error)
        }
    }

    func selectContext(_ name: String) async {
        guard name != selectedContext else { return }
        refreshTask?.cancel()
        refreshTask = nil

        selectedContext = name
        lastError = nil
        unreadEvents = 0                                     // recomputed for the new context by the counts poll
        kindCounts = countCache[name] ?? [:]                 // cached counts show instantly
        let cached = cachedRows(name, selectedKind)
        rows = cached ?? []
        onContextsChanged?()
        onCountsChanged?()
        onResourcesChanged?()
        onStateChanged?()

        startAutoRefresh()
        await refreshResources(showSpinner: cached == nil)   // load the visible kind first…
        startCountsRefresh()                                 // …then sidebar counts for the rest
    }

    func selectKind(_ kind: ResourceKind) async {
        guard kind != selectedKind else { return }
        let leavingEvents = selectedKind == .events
        refreshTask?.cancel()
        refreshTask = nil

        selectedKind = kind
        lastError = nil

        let cached = selectedContext.flatMap { cachedRows($0, kind) }
        rows = cached ?? []
        onKindChanged?()
        onResourcesChanged?()
        onStateChanged?()

        guard let ctx = selectedContext else { return }
        startAutoRefresh()
        // Leaving Events: recompute unread now so the badge starts climbing
        // immediately, not at the next 60s counts tick.
        if leavingEvents { Task { [weak self] in await self?.loadEventUnread(context: ctx) } }
        // Show a spinner only when we have nothing cached to display.
        await refreshResources(showSpinner: cached == nil)
    }

    func refreshNow() {
        Task { await refreshResources(showSpinner: true) }
    }

    func refreshResources(showSpinner: Bool) async {
        guard let ctx = selectedContext else { return }
        let kind = selectedKind
        let cmd = beginCommand(kubectlDisplay("get \(kind.kubectlResource) -A -o json"))
        if showSpinner { beginActivity("Loading \(kind.displayName.lowercased())…") }
        defer { if showSpinner { endActivity() }; endCommand(cmd) }
        do {
            let result = try await service.resources(kind: kind, context: ctx)
            var sorted = result.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
            if kind == .pods {
                // Join each pod's node → architecture. Only cache-backed resolution is
                // synchronous; a kubectl `get nodes` (low priority — it can queue behind
                // a counts burst) runs in a follow-up task so it never delays publishing
                // the visible pod rows. A stale map beats none while the refresh lands.
                if let map = quickNodeArch(context: ctx) {
                    sorted = Self.joinArch(sorted, map)
                } else {
                    if let old = nodeArchCache[ctx]?.map { sorted = Self.joinArch(sorted, old) }
                    scheduleArchJoin(context: ctx)
                }
            }
            storeRows(sorted, context: ctx, kind: kind)
            if kind == .events, selectedContext == ctx, selectedKind == .events {   // still viewing → mark read
                applyEventKeys(Set(sorted.map(\.key)), context: ctx)
            }
            countCache[ctx, default: [:]][kind] = sorted.count
            if selectedContext == ctx {
                kindCounts[kind] = sorted.count
                onCountsChanged?()
            }
            guard selectedContext == ctx, selectedKind == kind else { return }
            rows = sorted
            lastError = nil
            onResourcesChanged?()
            onStateChanged?()
        } catch {
            if error is CancellationError { return }
            // A stale failure (the kind/context switched while this poll was in
            // flight) must not paint an error over the new selection's data.
            guard selectedContext == ctx, selectedKind == kind else { return }
            setError(error)
        }
    }

    /// Best-effort fetch of the other kinds so the sidebar can show counts (and
    /// switching to them is instant). Errors per kind are ignored.
    private func prefetchOtherKindCounts() {
        guard let ctx = selectedContext else { return }
        // Disabled kinds are never queried.
        for kind in ResourceKind.allCases where kind != selectedKind && ResourceKindStore.isEnabled(kind) {
            Task { [weak self] in await self?.loadCount(for: kind, context: ctx) }
        }
    }

    /// Fetch the count for a single kind (e.g. right after it's re-enabled).
    func refreshCount(for kind: ResourceKind) {
        guard let ctx = selectedContext else { return }
        Task { [weak self] in await self?.loadCount(for: kind, context: ctx) }
    }

    private func loadCount(for kind: ResourceKind, context ctx: String) async {
        // Events show an "unread" badge, not a total — needs fresh identities, not a cached count.
        if kind == .events { await loadEventUnread(context: ctx); return }
        // Reuse fresh full data if we already have it — no extra `-o name` query.
        if let cached = cachedRows(ctx, kind) {
            countCache[ctx, default: [:]][kind] = cached.count
            if selectedContext == ctx {
                kindCounts[kind] = cached.count
                onCountsChanged?()
            }
            return
        }
        let cmd = beginCommand(kubectlDisplay("get \(kind.kubectlResource) -A -o name"))
        defer { endCommand(cmd) }
        do {
            let n = try await service.count(kind: kind, context: ctx)
            countCache[ctx, default: [:]][kind] = n
            guard selectedContext == ctx else { return }
            kindCounts[kind] = n
            onCountsChanged?()
        } catch {
            // ignore — counts are best-effort
        }
    }

    /// Fetch the current event identities (fresh — never cached, or new events would
    /// be masked) and recompute the unread badge.
    private func loadEventUnread(context ctx: String) async {
        let cmd = beginCommand(kubectlDisplay("get events -A -o name"))
        defer { endCommand(cmd) }
        guard let keys = try? await service.eventKeys(context: ctx) else { return }
        applyEventKeys(keys, context: ctx)
    }

    /// Diff a fresh set of event identities against the per-context "read" baseline.
    /// While Events is the visible kind, everything is read (baseline = current, 0
    /// unread); otherwise unread = events not in the baseline. First sight sets the
    /// baseline so a fresh launch doesn't count every existing event as unread.
    private func applyEventKeys(_ keys: Set<String>, context ctx: String) {
        if selectedKind == .events && selectedContext == ctx {
            // Viewing: everything shown is read. Union so a late/stale fetch can
            // only ever add to the baseline, never regress it.
            seenEventKeys[ctx] = (seenEventKeys[ctx] ?? []).union(keys)
            unreadEvents = 0
        } else {
            if seenEventKeys[ctx] == nil { seenEventKeys[ctx] = keys }   // first sight = baseline
            let base = seenEventKeys[ctx] ?? keys
            if selectedContext == ctx { unreadEvents = keys.subtracting(base).count }
            seenEventKeys[ctx] = base.intersection(keys)   // prune to current events — keeps the baseline bounded
        }
        if selectedContext == ctx { onCountsChanged?() }
    }

    private static func joinArch(_ rows: [ResourceRow], _ arch: [String: String]) -> [ResourceRow] {
        rows.map { row in
            var r = row
            r.cells["arch"] = row.cells["nodeName"].flatMap { arch[$0] } ?? ""
            return r
        }
    }

    /// Node-arch map when it's available without a kubectl call: a TTL-fresh cache
    /// entry, or already-loaded Nodes rows (they carry `cells["arch"]`).
    private func quickNodeArch(context ctx: String) -> [String: String]? {
        if let c = nodeArchCache[ctx], Date().timeIntervalSince(c.at) < nodeArchTTL { return c.map }
        if let nodeRows = cachedRows(ctx, .nodes) {
            let map = Dictionary(nodeRows.map { ($0.name, $0.cells["arch"] ?? "") },
                                 uniquingKeysWith: { a, _ in a })
            nodeArchCache[ctx] = ArchCache(map: map, at: Date())
            return map
        }
        return nil
    }

    /// Refresh the arch map in the background (best-effort — arch degrades to a dash
    /// on RBAC denial) and re-join it onto the already-published pod rows. In-flight
    /// guarded so overlapping 5s polls don't stack `get nodes` queries.
    private func scheduleArchJoin(context ctx: String) {
        guard !archJoinInFlight.contains(ctx) else { return }
        archJoinInFlight.insert(ctx)
        Task { [weak self] in
            guard let self else { return }
            defer { self.archJoinInFlight.remove(ctx) }
            let cmd = self.beginCommand(self.kubectlDisplay("get nodes -o json"))
            defer { self.endCommand(cmd) }
            guard let map = try? await self.service.nodeArchitectures(context: ctx) else { return }
            self.nodeArchCache[ctx] = ArchCache(map: map, at: Date())
            guard self.selectedContext == ctx, self.selectedKind == .pods, !map.isEmpty else { return }
            self.rows = Self.joinArch(self.rows, map)
            self.storeRows(self.rows, context: ctx, kind: .pods)
            self.onResourcesChanged?()
        }
    }

    // MARK: - Actions

    func performPrimaryAction(_ row: ResourceRow) {
        guard let ctx = selectedContext, let action = row.kind.primaryAction else { return }
        let res = row.kind.kubectlResource
        let nsFlag = row.namespace.isEmpty ? "" : " -n \(row.namespace)"   // cluster-scoped kinds (PV) have none
        let command = action == .delete
            ? kubectlDisplay("delete \(res) \(row.name)\(nsFlag)")
            : kubectlDisplay("rollout restart \(res)/\(row.name)\(nsFlag)")
        Task {
            let cmd = beginCommand(command)
            beginActivity("\(action.title) \(row.name)…")
            defer { endActivity(); endCommand(cmd) }
            do {
                switch action {
                case .delete:
                    try await service.delete(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name)
                case .restart:
                    try await service.restart(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name)
                }
                await refreshResources(showSpinner: false)
            } catch {
                setError(error)
            }
        }
    }

    func scale(_ row: ResourceRow, replicas: Int) {
        guard let ctx = selectedContext, row.kind.scalable else { return }
        Task {
            let cmd = beginCommand(kubectlDisplay("scale \(row.kind.kubectlResource)/\(row.name) --replicas=\(replicas) -n \(row.namespace)"))
            beginActivity("Scale \(row.name) → \(replicas)…")
            defer { endActivity(); endCommand(cmd) }
            do {
                try await service.scale(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name, replicas: replicas)
                await refreshResources(showSpinner: false)
            } catch {
                setError(error)
            }
        }
    }

    /// Current desired replica count of a scalable row (for the scale dialog).
    func currentReplicas(_ row: ResourceRow) -> Int {
        Int(row.sortValues["desired"] ?? 0)
    }

    /// Start following a pod's logs. Returns a stoppable handle (nil if not a pod).
    func streamLogs(for row: ResourceRow,
                    onLine: @escaping @Sendable (String) -> Void,
                    onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess? {
        guard let ctx = selectedContext, row.kind == .pods else { return nil }
        return service.streamLogs(context: ctx, namespace: row.namespace, pod: row.name,
                                  container: nil, onLine: onLine, onEnd: onEnd)
    }

    /// Start a `kubectl port-forward`. Returns a stoppable handle (nil if no context).
    func portForward(namespace: String, resource: String, name: String, local: Int, remote: Int,
                     onLine: @escaping @Sendable (String) -> Void,
                     onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess? {
        guard let ctx = selectedContext else { return nil }
        return service.portForward(context: ctx, namespace: namespace, resource: resource, name: name,
                                   localPort: local, remotePort: remote, onLine: onLine, onEnd: onEnd)
    }

    /// `kubectl rollout undo` — nil revision = previous. Refresh once it lands.
    func rollback(_ row: ResourceRow, toRevision: Int?) {
        guard let ctx = selectedContext, row.kind.rollbackable else { return }
        Task {
            let target = toRevision.map { " --to-revision=\($0)" } ?? ""
            let cmd = beginCommand(kubectlDisplay("rollout undo \(row.kind.kubectlResource)/\(row.name)\(target) -n \(row.namespace)"))
            beginActivity(toRevision.map { "Roll back \(row.name) → rev \($0)…" } ?? "Roll back \(row.name)…")
            defer { endActivity(); endCommand(cmd) }
            do {
                try await service.rollback(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name, toRevision: toRevision)
                await refreshResources(showSpinner: false)
            } catch {
                setError(error)
            }
        }
    }

    // MARK: - Detail panel

    func detailText(for row: ResourceRow, section: DetailSection) async throws -> String {
        let ctx = selectedContext ?? ""
        let text = try await fetchDetailText(for: row, section: section)
        storeDetail(detailKey(ctx, row, "text.\(section.rawValue)"), text)
        return text
    }

    private func fetchDetailText(for row: ResourceRow, section: DetailSection) async throws -> String {
        guard let ctx = selectedContext else { return "" }
        if row.kind == .nodes {
            if section == .pods { return "" }   // rendered as a native table via nodePods(for:)
            let cmd = beginCommand(kubectlDisplay("describe node \(row.name)"))
            defer { endCommand(cmd) }
            return try await service.describeNode(context: ctx, name: row.name)
        }
        if row.kind == .namespaces {
            if section == .resources { return "" }   // rendered as a table via namespaceInventory(for:)
            let cmd = beginCommand(kubectlDisplay("describe namespace \(row.name)"))
            defer { endCommand(cmd) }
            return try await service.describeNamespace(context: ctx, name: row.name)
        }
        if row.kind == .events {
            // Built from the row's own fields — no extra query. The "Key: value"
            // shape is colored by DescribeFormatter; "Message:" becomes a header.
            return """
            Object:    \(row.value("object"))
            Type:      \(row.value("type"))
            Reason:    \(row.value("reason"))
            Count:     \(row.value("count"))
            Source:    \(row.value("source"))
            Namespace: \(row.namespace.isEmpty ? "—" : row.namespace)
            First:     \(row.value("first"))
            Last Seen: \(row.value("age"))

            Message:
            \(row.value("message"))
            """
        }
        if section == .health || section == .containers || section == .mounts {
            let cmd = beginCommand(kubectlDisplay("get pod \(row.name) -n \(row.namespace) -o json"))
            defer { endCommand(cmd) }
            let pod = try await service.podDetail(context: ctx, namespace: row.namespace, name: row.name)
            switch section {
            case .health:     return PodStatusDerivation.healthReport(pod)
            case .containers: return PodStatusDerivation.containersReport(pod)
            default:          return PodStatusDerivation.mountsReport(pod)
            }
        }
        if section == .history {
            let cmd = beginCommand(kubectlDisplay("rollout history \(row.kind.kubectlResource)/\(row.name) -n \(row.namespace)"))
            defer { endCommand(cmd) }
            let text = try await service.rolloutHistory(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No rollout history." : text
        }
        if section == .logs && row.kind != .pods {
            return "Logs are available for pods."
        }
        if section == .top || section == .metrics {
            return ""   // rendered via detailTop(for:) / podMetrics(for:); not through reloadDetail's text path.
        }
        let tail: String
        switch section {
        case .overview: tail = "describe \(row.kind.singularName) \(row.name) -n \(row.namespace)"
        case .logs: tail = "logs \(row.name) -n \(row.namespace) --tail=1000 --all-containers"
        case .events: tail = "get events -n \(row.namespace) --field-selector involvedObject.name=\(row.name)"
        case .top, .pods, .resources, .health, .containers, .mounts, .history, .metrics, .shell: tail = ""   // handled above
        }
        let cmd = beginCommand(kubectlDisplay(tail))
        defer { endCommand(cmd) }
        let text: String
        switch section {
        case .overview:
            text = try await service.describe(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name)
        case .logs:
            text = try await service.logs(context: ctx, namespace: row.namespace, name: row.name)
        case .events:
            text = try await service.events(context: ctx, namespace: row.namespace, name: row.name)
        case .top, .pods, .resources, .health, .containers, .mounts, .history, .metrics, .shell:
            text = ""   // handled above
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            switch section {
            case .logs: return "(no logs)"
            case .events: return "No recent events."
            case .overview: return "(no output)"
            case .top, .pods, .resources, .health, .containers, .mounts, .history, .metrics, .shell: return ""
            }
        }
        return text
    }

    /// `kubectl top pod --containers` (resource usage) + an in-container process
    /// list via exec, parsed into a structured `PodTopReport`. Both halves are
    /// best-effort so one failing still shows the other.
    func detailTop(for row: ResourceRow) async throws -> PodTopReport {
        guard let ctx = selectedContext else { return .empty }
        let cmd = beginCommand(kubectlDisplay("top pod \(row.name) -n \(row.namespace) --containers"))
        defer { endCommand(cmd) }

        async let metricsResult = service.topPod(context: ctx, namespace: row.namespace, name: row.name)
        async let procsResult = service.podProcesses(context: ctx, namespace: row.namespace, name: row.name)

        var report = PodTopReport()
        report.podNamespace = row.namespace
        report.podName = row.name
        // Pod-level requests (already parsed for the table columns) feed the bar ticks.
        report.cpuRequestMillis = row.sortValues["cpu"] ?? 0
        report.memRequestBytes = row.sortValues["mem"] ?? 0

        do {
            let raw = try await metricsResult
            report.containers = TopParser.parseContainers(raw)
            if report.containers.isEmpty { report.metricsNote = "no container metrics" }
        } catch {
            report.metricsNote = "metrics unavailable — \(Self.firstLine(error.localizedDescription))"
        }

        do {
            let raw = try await procsResult
            let parsed = TopParser.parseProcesses(raw)
            report.summary = parsed.summary
            report.node = TopParser.parseNode(parsed.summary)
            report.processColumns = parsed.columns
            report.processes = parsed.rows
            if parsed.rows.isEmpty {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                report.processNote = t.isEmpty ? "no processes returned" : t
            }
        } catch {
            report.processNote = "exec unavailable — \(Self.firstLine(error.localizedDescription))"
        }

        // Both halves swallow errors into notes — including CancellationError now
        // that cancellation kills the kubectl calls — so bail before a cancelled
        // fetch poisons the detail cache with an empty "unavailable" report.
        try Task.checkCancellation()
        storeDetail(detailKey(ctx, row, "top"), report)
        return report
    }

    /// All resource entities in a namespace, for the namespace detail table.
    func namespaceInventory(for row: ResourceRow) async throws -> [NamespaceResource] {
        guard let ctx = selectedContext else { return [] }
        let cmd = beginCommand(kubectlDisplay("get <resources> -n \(row.name) -o name"))
        defer { endCommand(cmd) }
        let items = try await service.namespaceInventory(context: ctx, namespace: row.name)
        storeDetail(detailKey(ctx, row, "inventory"), items)
        return items
    }

    /// Pods scheduled on a node (for the node detail "Pods" table).
    func nodePods(for row: ResourceRow) async throws -> [ResourceRow] {
        guard let ctx = selectedContext else { return [] }
        let cmd = beginCommand(kubectlDisplay("get pods -A --field-selector spec.nodeName=\(row.name)"))
        defer { endCommand(cmd) }
        let pods = try await service.podsOnNode(context: ctx, node: row.name)
        storeDetail(detailKey(ctx, row, "nodepods"), pods)
        return pods
    }

    /// A single resource's Events as structured rows (for the native Events table).
    func resourceEvents(for row: ResourceRow) async throws -> [ResourceRow] {
        guard let ctx = selectedContext else { return [] }
        let cmd = beginCommand(kubectlDisplay("get events -n \(row.namespace) --field-selector involvedObject.name=\(row.name)"))
        defer { endCommand(cmd) }
        let events = try await service.resourceEvents(context: ctx, namespace: row.namespace, name: row.name)
        storeDetail(detailKey(ctx, row, "events"), events)
        return events
    }

    /// Scrape a pod's Prometheus `/metrics` into a parsed report for the Metrics
    /// tab. `override` supplies an explicit endpoint (from the tab's port/path
    /// fields); otherwise it's discovered from the pod's annotations/ports.
    /// Expected failures (no port, scrape error) come back as a `note` — with the
    /// endpoint preserved so the user can fix the port/path and retry.
    func podMetrics(for row: ResourceRow, override: MetricEndpoint?) async throws -> MetricsReport {
        guard let ctx = selectedContext else {
            return MetricsReport(endpoint: override, document: MetricsDocument(), note: "No context selected.")
        }
        let endpoint: MetricEndpoint
        if let override {
            endpoint = override
        } else {
            let cmd = beginCommand(kubectlDisplay("get pod \(row.name) -n \(row.namespace) -o json (+ ServiceMonitors)"))
            // Fetch the pod and the operator monitors concurrently; monitors are
            // best-effort (empty without prometheus-operator) so they never throw.
            async let sourcesTask = service.metricsSources(context: ctx, namespace: row.namespace)
            let pod: K8sPod
            do { pod = try await service.podDetail(context: ctx, namespace: row.namespace, name: row.name) }
            catch { endCommand(cmd); _ = await sourcesTask; throw error }
            let sources = await sourcesTask
            endCommand(cmd)
            let guess = MetricsDiscovery.discover(pod: pod, sources: sources)
            guard guess.confident else {
                // Only a guess — pre-fill the port and let the user confirm with Load
                // (scraping a wrong, non-HTTP port could stall the port-forward).
                return MetricsReport(endpoint: guess.endpoint, document: MetricsDocument(),
                    note: "No metrics port is declared on this pod. Guessed port \(guess.endpoint.port) from its container ports — press Load to scrape, or edit the port/path first.")
            }
            endpoint = guess.endpoint
        }
        let cmd = beginCommand(kubectlDisplay("port-forward pod/\(row.name) -n \(row.namespace) :\(endpoint.port) → GET \(endpoint.path)"))
        defer { endCommand(cmd) }
        do {
            let raw = try await service.podMetrics(context: ctx, namespace: row.namespace, pod: row.name, endpoint: endpoint)
            // Parse off the main actor — a large exposition doc shouldn't jank the UI.
            let document = await Task.detached { PrometheusParser.parse(raw) }.value
            let note = document.samples.isEmpty ? "No metrics returned from \(endpoint.path) (port \(endpoint.port))." : nil
            let report = MetricsReport(endpoint: endpoint, document: document, note: note)
            if !document.samples.isEmpty { storeDetail(detailKey(ctx, row, "metrics"), report) }
            return report
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return MetricsReport(endpoint: endpoint, document: MetricsDocument(),
                note: "Couldn’t scrape \(endpoint.path) on port \(endpoint.port):\n\(Self.firstLine(error.localizedDescription))")
        }
    }

    // MARK: - Diagnostics (heap dump / async-profiler)

    private func diagTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// Best-effort, fire-and-forget removal of diagnostic leftovers in the pod.
    /// Must run on failure paths too — a dead transfer would otherwise strand a
    /// multi-GB dump in the pod's /tmp (disk-pressure/eviction risk on prod).
    private func cleanupRemote(context ctx: String, namespace ns: String, pod: String, paths: String) {
        let svc = service
        Task { _ = try? await svc.exec(context: ctx, namespace: ns, pod: pod,
                                       args: ["/bin/sh", "-lc", "rm -rf \(paths)"], timeoutSeconds: 60) }
    }

    /// `jcmd GC.heap_dump` on the given in-container PID, gzip, copy out, gunzip
    /// locally. Returns the saved file URL.
    func heapDump(namespace ns: String, name pod: String, pid: String) async throws -> URL {
        guard let ctx = selectedContext else { throw KubectlError(message: "No context selected", code: 1) }
        let ts = diagTimestamp()
        let remoteHprof = "/tmp/heap-\(ts).hprof", remoteGz = remoteHprof + ".gz"

        // Locate jcmd next to the JVM's own binary (generic), with fallbacks.
        let script = """
        set -e
        PID=\(pid)
        JCMD=""
        EXE=$(readlink -f /proc/$PID/exe 2>/dev/null || true)
        if [ -n "$EXE" ] && [ -x "$(dirname "$EXE")/jcmd" ]; then JCMD="$(dirname "$EXE")/jcmd"; fi
        if [ -z "$JCMD" ]; then JCMD=$(command -v jcmd 2>/dev/null || true); fi
        if [ -z "$JCMD" ] && [ -x /fx/bin/jcmd ]; then JCMD=/fx/bin/jcmd; fi
        if [ -z "$JCMD" ]; then echo "jcmd not found for PID $PID" >&2; exit 3; fi
        "$JCMD" $PID GC.heap_dump \(remoteHprof)
        gzip -f \(remoteHprof)
        ls -lh \(remoteGz)
        """
        let c1 = beginCommand(kubectlDisplay("exec \(pod) -- jcmd \(pid) GC.heap_dump"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod,
                                        args: ["/bin/sh", "-lc", script], timeoutSeconds: 900) }
        catch {
            endCommand(c1)
            cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: "\(remoteHprof) \(remoteGz)")
            throw error
        }
        endCommand(c1)

        let dir = DiagnosticPaths.dumpsDir(ns)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let localGz = "\(dir)/\(ts).hprof.gz"
        let c2 = beginCommand(kubectlDisplay("cp \(pod):\(remoteGz)"))
        do { try await service.copyFromPod(context: ctx, namespace: ns, pod: pod,
                                           remotePath: remoteGz, localPath: localGz) }
        catch {
            endCommand(c2)
            cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: remoteGz)
            throw error
        }
        endCommand(c2)

        // Free the pod's /tmp; decompress the local copy.
        cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: remoteGz)
        let localHprof = "\(dir)/\(ts).hprof"
        _ = try? await LocalProcess.run("/usr/bin/gunzip", ["-f", localGz])
        return URL(fileURLWithPath: FileManager.default.fileExists(atPath: localHprof) ? localHprof : localGz)
    }

    /// Upload async-profiler, run `asprof` for `seconds`, copy the JFR out.
    func profile(namespace ns: String, name pod: String, pid: String, preset: AsyncProfile, seconds: Int) async throws -> URL {
        guard let ctx = selectedContext else { throw KubectlError(message: "No context selected", code: 1) }
        guard let tarURL = DiagnosticPaths.asyncProfilerTar,
              FileManager.default.fileExists(atPath: tarURL.path) else {
            throw KubectlError(message: "Bundled async-profiler (\(DiagnosticPaths.asyncProfilerDir).tar) not found in app Resources", code: 1)
        }
        let tarLocal = tarURL.path
        let ts = diagTimestamp()
        let work = "/tmp/aprof"
        let remoteTar = "\(work)/async-profiler.tar"
        let remoteOut = "\(work)/\(preset.rawValue)-\(ts).jfr"
        let asprof = "\(work)/\(DiagnosticPaths.asyncProfilerDir)/bin/asprof"

        let cPrep = beginCommand(kubectlDisplay("exec \(pod) -- prepare async-profiler"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod,
                                        args: ["/bin/sh", "-lc", "rm -rf \(work) && mkdir -p \(work)"], timeoutSeconds: 60) }
        catch { endCommand(cPrep); throw error }
        endCommand(cPrep)

        let cUp = beginCommand(kubectlDisplay("cp async-profiler → \(pod)"))
        do { try await service.copyToPod(context: ctx, namespace: ns, pod: pod,
                                         localPath: tarLocal, remotePath: remoteTar) }
        catch { endCommand(cUp); cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: work); throw error }
        endCommand(cUp)

        let cUnpack = beginCommand(kubectlDisplay("exec \(pod) -- unpack async-profiler"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod,
                                        args: ["/bin/sh", "-lc", "tar -xf \(remoteTar) -C \(work) && chmod -R a+rx \(work)"], timeoutSeconds: 120) }
        catch { endCommand(cUnpack); cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: work); throw error }
        endCommand(cUnpack)

        let args = preset.asprofArgs(pid: pid, seconds: seconds, outPath: remoteOut)
        let cRun = beginCommand(kubectlDisplay("exec \(pod) -- asprof \(preset.rawValue) -d \(seconds)s"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod,
                                        args: ["/bin/sh", "-lc", "\(asprof) \(args)"], timeoutSeconds: seconds + 120) }
        catch { endCommand(cRun); cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: work); throw error }
        endCommand(cRun)

        let dir = DiagnosticPaths.profilesDir(ns)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let localOut = "\(dir)/\(preset.rawValue)-\(ts).jfr"
        let cDown = beginCommand(kubectlDisplay("cp \(pod):\(remoteOut)"))
        do { try await service.copyFromPod(context: ctx, namespace: ns, pod: pod,
                                           remotePath: remoteOut, localPath: localOut) }
        catch { endCommand(cDown); cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: work); throw error }
        endCommand(cDown)
        // The tar + extracted profiler + JFR (~100MB) are all under `work` — the next
        // run re-uploads anyway, so don't leave them in the pod between runs.
        cleanupRemote(context: ctx, namespace: ns, pod: pod, paths: work)
        return URL(fileURLWithPath: localOut)
    }

    /// First non-empty line of a (possibly multi-line) kubectl error, for compact display.
    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? text
    }

    // MARK: - Auto-refresh

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let interval = self?.refreshInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.refreshResources(showSpinner: false)
            }
        }
    }

    /// Poll the counts of the *other* kinds for the sidebar, far less often than
    /// the visible kind (which refreshes every 5s via startAutoRefresh).
    private func startCountsRefresh() {
        countsTask?.cancel()
        countsTask = Task { [weak self] in
            guard let interval = self?.countsInterval else { return }
            while !Task.isCancelled {
                self?.prefetchOtherKindCounts()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func pause() {
        refreshTask?.cancel()
        refreshTask = nil
        countsTask?.cancel()
        countsTask = nil
    }

    func resume() {
        guard selectedContext != nil else { return }
        if refreshTask == nil { startAutoRefresh() }
        if countsTask == nil { startCountsRefresh() }
    }

    // MARK: - Private

    private func beginActivity(_ message: String) {
        activity = message
        isLoading = true
        onStateChanged?()
    }

    private func endActivity() {
        activity = nil
        isLoading = false
        onStateChanged?()
    }

    private func setError(_ error: Error) {
        lastError = error.localizedDescription
        onStateChanged?()
    }

    private func beginCommand(_ command: String) -> Int {
        inflightCounter += 1
        let id = inflightCounter
        inflight.append((id, command))
        onStateChanged?()
        return id
    }

    private func endCommand(_ id: Int) {
        inflight.removeAll { $0.id == id }
        onStateChanged?()
    }

    private func kubectlDisplay(_ tail: String) -> String {
        if let ctx = contextInfo(selectedContext) {
            return "kubectl --context \(ctx.displayName) \(tail)"
        }
        return "kubectl \(tail)"
    }
}
