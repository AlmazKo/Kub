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

    /// Main-container resolution per pod (`PodContainers.main`), cached so the ~3s Top
    /// poll and each diagnostic step don't re-fetch the pod spec. Keyed context|ns|pod.
    private var mainContainerCache: [String: (name: String?, at: Date)] = [:]

    /// The cached app-container name for a pod of the selected context, if resolved
    /// recently; nil = unknown (or genuinely none) → let kubectl pick its default.
    func cachedMainContainer(namespace: String, pod: String) -> String? {
        guard let ctx = selectedContext, let e = mainContainerCache["\(ctx)|\(namespace)|\(pod)"],
              Date().timeIntervalSince(e.at) < cacheTTL else { return nil }
        return e.name
    }

    /// Resolve (and cache) the container that process-level actions target. nil when
    /// the pod can't be read — the caller then leaves the choice to kubectl.
    func mainContainer(namespace: String, pod: String) async -> String? {
        guard let ctx = selectedContext else { return nil }
        if let cached = cachedMainContainer(namespace: namespace, pod: pod) { return cached }
        guard let detail = try? await service.podDetail(context: ctx, namespace: namespace, name: pod) else { return nil }
        let name = PodContainers.main(of: detail)
        mainContainerCache["\(ctx)|\(namespace)|\(pod)"] = (name, Date())
        return name
    }

    /// CPU architecture of the node a pod runs on, from the already-joined pod rows
    /// (nil when unknown). Picks the async-profiler build to upload.
    private func podArch(namespace: String, pod: String) -> String? {
        guard let ctx = selectedContext else { return nil }
        let arch = rowCache[ctx]?[.pods]?.rows.first { $0.namespace == namespace && $0.name == pod }?.cells["arch"] ?? ""
        return arch.isEmpty ? nil : arch
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
        let cmd = beginCommand(kubectlDisplay(Self.listCommand(kind)))
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
        // Reuse fresh full data if we already have it — no extra count query.
        if let cached = cachedRows(ctx, kind) {
            countCache[ctx, default: [:]][kind] = cached.count
            if selectedContext == ctx {
                kindCounts[kind] = cached.count
                onCountsChanged?()
            }
            return
        }
        let cmd = beginCommand(kubectlDisplay("get --raw \(kind.apiPath)?limit=1"))
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
            ? kubectlDisplay("delete \(res) \(row.name)\(nsFlag) --wait=false")
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
        // The READY cell's total ("1/2") counts app containers + native sidecars —
        // exactly the ones `--all-containers` streams.
        let containers = Int(row.value("ready").split(separator: "/").last ?? "") ?? 1
        return service.streamLogs(context: ctx, namespace: row.namespace, pod: row.name,
                                  container: nil, prefix: containers > 1, onLine: onLine, onEnd: onEnd)
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
        // Only Overview is text from here on. Pod logs stream (LiveLogView), Events is
        // the native table (resourceEvents), Top/Metrics/Shell have their own views.
        guard section == .overview else { return "" }
        let cmd = beginCommand(kubectlDisplay("describe \(row.kind.singularName) \(row.name)\(row.namespace.isEmpty ? "" : " -n \(row.namespace)")"))
        defer { endCommand(cmd) }
        let text = try await service.describe(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no output)" : text
    }

    /// `kubectl top pod --containers` (resource usage) + an in-container process
    /// list via exec, parsed into a structured `PodTopReport`. Both halves are
    /// best-effort so one failing still shows the other.
    func detailTop(for row: ResourceRow) async throws -> PodTopReport {
        guard let ctx = selectedContext else { return .empty }
        let cmd = beginCommand(kubectlDisplay("top pod \(row.name) -n \(row.namespace) --containers"))
        defer { endCommand(cmd) }

        // The process list (and any PID the user acts on from it) is per container —
        // pin it to the app container rather than kubectl's first-listed one.
        let container = await mainContainer(namespace: row.namespace, pod: row.name)
        let psCmd = beginCommand(kubectlDisplay("exec \(row.name) -n \(row.namespace)\(Self.containerFlag(container)) -- top -bn1"))
        defer { endCommand(psCmd) }
        async let metricsResult = service.topPod(context: ctx, namespace: row.namespace, name: row.name)
        async let procsResult = service.podProcesses(context: ctx, namespace: row.namespace, name: row.name, container: container)

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
        let cmd = beginCommand(kubectlDisplay("get <resources> -n \(row.name) -o json (+ secrets --no-headers)"))
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
        let cmd = beginCommand(kubectlDisplay("get events -n \(row.namespace) --field-selector involvedObject.name=\(row.name),involvedObject.kind=\(row.kind.apiKind)"))
        defer { endCommand(cmd) }
        let events = try await service.resourceEvents(kind: row.kind, context: ctx, namespace: row.namespace, name: row.name)
        storeDetail(detailKey(ctx, row, "events"), events)
        return events
    }

    /// Scrape a pod's Prometheus `/metrics` into a parsed report for the Metrics
    /// tab. `override` supplies an explicit endpoint (from the tab's port/path
    /// fields); otherwise it's discovered (Service/PodMonitor → `prometheus.io` annotations
    /// on the pod or its Service → named metrics port → guess).
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
            let cmd = beginCommand(kubectlDisplay("get pod \(row.name) -n \(row.namespace) -o json (+ servicemonitors/podmonitors -A, services)"))
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
                    note: "No metrics port is declared on this pod. Guessed port \(guess.endpoint.port) — press Load to scrape, or edit the port/path first.")
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
    private func cleanupRemote(context ctx: String, namespace ns: String, pod: String, container: String?, paths: String) {
        let svc = service
        Task { _ = try? await svc.exec(context: ctx, namespace: ns, pod: pod, container: container,
                                       args: ["/bin/sh", "-lc", "rm -rf \(paths)"], timeoutSeconds: 60) }
    }

    /// `jcmd GC.heap_dump` on the given in-container PID, gzip, copy out, gunzip
    /// locally. Returns the saved file URL. Every step names the same container the
    /// PID was listed in (a sidecar pod has one PID namespace per container).
    func heapDump(namespace ns: String, name pod: String, pid: String) async throws -> URL {
        guard let ctx = selectedContext else { throw KubectlError(message: "No context selected.", code: -1) }
        let container = await mainContainer(namespace: ns, pod: pod)
        let ts = diagTimestamp()
        let base = "heap-\(ts).hprof"
        // Wherever the dump landed, these globs cover it (for cleanup on failure).
        let leftovers = "/tmp/\(base)* /var/tmp/\(base)* \"${TMPDIR:-/nonexistent}\"/\(base)*"

        // Locate jcmd next to the JVM's own binary (generic), with fallbacks; then pick
        // a writable directory with room: the .hprof is about the live heap and gzip
        // needs space for its output alongside, so require ~1.3× the JVM's RSS.
        // Hardened pods often mount a read-only root fs — try the usual places in order.
        // jcmd's chatter goes to stderr so stdout's last line is the finished .gz path.
        let script = """
        set -e
        PID=\(pid)
        JCMD=""
        EXE=$(readlink -f /proc/$PID/exe 2>/dev/null || true)
        if [ -n "$EXE" ] && [ -x "$(dirname "$EXE")/jcmd" ]; then JCMD="$(dirname "$EXE")/jcmd"; fi
        if [ -z "$JCMD" ] && [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/jcmd" ]; then JCMD="$JAVA_HOME/bin/jcmd"; fi
        if [ -z "$JCMD" ]; then JCMD=$(command -v jcmd 2>/dev/null || true); fi
        if [ -z "$JCMD" ]; then echo "jcmd not found for PID $PID — a heap dump needs a JDK in the container (JRE-only image?)" >&2; exit 3; fi
        RSS_KB=$(awk '/VmRSS/ {print $2}' /proc/$PID/status 2>/dev/null); RSS_KB=${RSS_KB:-0}
        NEED_KB=$((RSS_KB * 13 / 10))
        DIR=""
        for d in "${TMPDIR:-}" /tmp /var/tmp "$PWD"; do
          [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] || continue
          FREE_KB=$(df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $4}')
          if [ -n "$FREE_KB" ] && [ "$FREE_KB" -gt "$NEED_KB" ]; then DIR="$d"; break; fi
        done
        if [ -z "$DIR" ]; then echo "no writable directory with ${NEED_KB}KB free for the heap dump (checked \\$TMPDIR, /tmp, /var/tmp, cwd)" >&2; exit 4; fi
        OUT="$DIR/\(base)"
        "$JCMD" $PID GC.heap_dump "$OUT" >&2
        gzip -f "$OUT"
        echo "$OUT.gz"
        """
        let target = "\(pod) -n \(ns)\(Self.containerFlag(container))"
        let c1 = beginCommand(kubectlDisplay("exec \(target) -- jcmd \(pid) GC.heap_dump"))
        let remoteGz: String
        do {
            let out = try await service.exec(context: ctx, namespace: ns, pod: pod, container: container,
                                             args: ["/bin/sh", "-lc", script], timeoutSeconds: 900)
            guard let last = out.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces),
                  last.hasSuffix("\(base).gz") else {
                throw KubectlError(message: "heap dump did not report its output file:\n\(out.suffix(300))", code: 1)
            }
            remoteGz = last
        } catch {
            endCommand(c1)
            cleanupRemote(context: ctx, namespace: ns, pod: pod, container: container, paths: leftovers)
            throw error
        }
        endCommand(c1)

        let dir = DiagnosticPaths.dumpsDir(ns)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let localGz = "\(dir)/\(ts).hprof.gz"
        let c2 = beginCommand(kubectlDisplay("cp\(Self.containerFlag(container)) \(ns)/\(pod):\(remoteGz) \(localGz)"))
        do { try await service.copyFromPod(context: ctx, namespace: ns, pod: pod, container: container,
                                           remotePath: remoteGz, localPath: localGz) }
        catch {
            endCommand(c2)
            cleanupRemote(context: ctx, namespace: ns, pod: pod, container: container, paths: remoteGz)
            throw error
        }
        endCommand(c2)

        // Free the pod's disk; decompress the local copy.
        cleanupRemote(context: ctx, namespace: ns, pod: pod, container: container, paths: remoteGz)
        let localHprof = "\(dir)/\(ts).hprof"
        _ = try? await LocalProcess.run("/usr/bin/gunzip", ["-f", localGz])
        return URL(fileURLWithPath: FileManager.default.fileExists(atPath: localHprof) ? localHprof : localGz)
    }

    /// Upload async-profiler (the build matching the node's CPU architecture), run
    /// `asprof` for `seconds`, copy the JFR out.
    func profile(namespace ns: String, name pod: String, pid: String, preset: AsyncProfile, seconds: Int) async throws -> URL {
        guard let ctx = selectedContext else { throw KubectlError(message: "No context selected.", code: -1) }
        let arch = podArch(namespace: ns, pod: pod)
        guard let profilerDir = DiagnosticPaths.asyncProfilerDir(arch: arch) else {
            throw KubectlError(message: "async-profiler has no build for node architecture “\(arch ?? "?")” (bundled: x64, arm64)", code: 1)
        }
        guard let tarURL = DiagnosticPaths.asyncProfilerTar(arch: arch),
              FileManager.default.fileExists(atPath: tarURL.path) else {
            throw KubectlError(message: "Bundled async-profiler (\(profilerDir).tar) not found in app Resources", code: 1)
        }
        let container = await mainContainer(namespace: ns, pod: pod)
        let tarLocal = tarURL.path
        let ts = diagTimestamp()
        let work = "/tmp/aprof"
        let remoteTar = "\(work)/async-profiler.tar"
        let remoteOut = "\(work)/\(preset.rawValue)-\(ts).jfr"
        let asprof = "\(work)/\(profilerDir)/bin/asprof"
        func cleanup() { cleanupRemote(context: ctx, namespace: ns, pod: pod, container: container, paths: work) }

        let target = "\(pod) -n \(ns)\(Self.containerFlag(container))"
        let cPrep = beginCommand(kubectlDisplay("exec \(target) -- mkdir -p \(work)"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod, container: container,
                                        args: ["/bin/sh", "-lc", "rm -rf \(work) && mkdir -p \(work)"], timeoutSeconds: 60) }
        catch { endCommand(cPrep); throw error }
        endCommand(cPrep)

        let cUp = beginCommand(kubectlDisplay("cp\(Self.containerFlag(container)) \(profilerDir).tar \(ns)/\(pod):\(remoteTar)"))
        do { try await service.copyToPod(context: ctx, namespace: ns, pod: pod, container: container,
                                         localPath: tarLocal, remotePath: remoteTar) }
        catch { endCommand(cUp); cleanup(); throw error }
        endCommand(cUp)

        let cUnpack = beginCommand(kubectlDisplay("exec \(target) -- tar -xf \(remoteTar)"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod, container: container,
                                        args: ["/bin/sh", "-lc", "tar -xf \(remoteTar) -C \(work) && chmod -R a+rx \(work)"], timeoutSeconds: 120) }
        catch { endCommand(cUnpack); cleanup(); throw error }
        endCommand(cUnpack)

        let args = preset.asprofArgs(pid: pid, seconds: seconds, outPath: remoteOut)
        let cRun = beginCommand(kubectlDisplay("exec \(target) -- asprof \(args)"))
        do { _ = try await service.exec(context: ctx, namespace: ns, pod: pod, container: container,
                                        args: ["/bin/sh", "-lc", "\(asprof) \(args)"], timeoutSeconds: seconds + 120) }
        catch { endCommand(cRun); cleanup(); throw error }
        endCommand(cRun)

        let dir = DiagnosticPaths.profilesDir(ns)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let localOut = "\(dir)/\(preset.rawValue)-\(ts).jfr"
        let cDown = beginCommand(kubectlDisplay("cp\(Self.containerFlag(container)) \(ns)/\(pod):\(remoteOut) \(localOut)"))
        do { try await service.copyFromPod(context: ctx, namespace: ns, pod: pod, container: container,
                                           remotePath: remoteOut, localPath: localOut) }
        catch { endCommand(cDown); cleanup(); throw error }
        endCommand(cDown)
        // The tar + extracted profiler + JFR (~100MB) are all under `work` — the next
        // run re-uploads anyway, so don't leave them in the pod between runs.
        cleanup()
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

    /// ` -c <name>` for the status-bar text of a container-pinned command ("" for nil).
    private static func containerFlag(_ container: String?) -> String {
        container.map { " -c \($0)" } ?? ""
    }

    /// What `resources(kind:)` actually runs, for the status bar.
    private static func listCommand(_ kind: ResourceKind) -> String {
        if kind == .secrets { return "get secrets -A --no-headers" }
        if kind == .nodes { return "get nodes -o json (+ top nodes)" }
        return "get \(kind.kubectlResource)\(kind.isNamespaced ? " -A" : "") -o json"
    }

    private func kubectlDisplay(_ tail: String) -> String {
        if let ctx = contextInfo(selectedContext) {
            return "kubectl --context \(ctx.displayName) \(tail)"
        }
        return "kubectl \(tail)"
    }
}
