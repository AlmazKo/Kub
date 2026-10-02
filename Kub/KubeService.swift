import Foundation

/// Abstraction over the cluster data source. Backed by `kubectl` today; can be
/// swapped for a native API client later without touching the UI/view-model.
protocol KubeService: Sendable {
    func contexts() async throws -> (contexts: [ClusterContext], current: String?)
    /// All resources of `kind` across every namespace of the context.
    func resources(kind: ResourceKind, context: String) async throws -> [ResourceRow]
    /// Element count of `kind` for the sidebar: `get --raw <apiPath>?limit=1` +
    /// `metadata.remainingItemCount`, with `-o name` only as the fallback.
    func count(kind: ResourceKind, context: String) async throws -> Int
    /// Identities (metadata.name) of all events — for the sidebar "unread" badge.
    func eventKeys(context: String) async throws -> Set<String>
    func delete(kind: ResourceKind, context: String, namespace: String, name: String) async throws
    func restart(kind: ResourceKind, context: String, namespace: String, name: String) async throws
    func scale(kind: ResourceKind, context: String, namespace: String, name: String, replicas: Int) async throws
    /// `kubectl rollout history` text for a controller (revisions + change-cause).
    func rolloutHistory(kind: ResourceKind, context: String, namespace: String, name: String) async throws -> String
    /// `kubectl rollout undo` — nil revision rolls back to the previous one.
    func rollback(kind: ResourceKind, context: String, namespace: String, name: String, toRevision: Int?) async throws

    // Detail panel (return human-readable text straight from kubectl).
    func describe(kind: ResourceKind, context: String, namespace: String, name: String) async throws -> String
    /// Follow a pod's logs (`logs -f`). Lines arrive via `onLine` (off-main); the
    /// stream ends with `onEnd` (nil = clean/stopped). Returns a stoppable handle.
    /// `prefix` tags each line with its container (`[pod/<pod>/<container>]`) — only
    /// worth it when the pod has more than one, or the lines are indistinguishable.
    func streamLogs(context: String, namespace: String, pod: String, container: String?, prefix: Bool,
                    onLine: @escaping @Sendable (String) -> Void,
                    onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess
    /// Events of one object. `kind` is part of the selector: a Deployment, its Service
    /// and its HPA usually share a name, and `involvedObject.name` alone mixes them.
    func resourceEvents(kind: ResourceKind, context: String, namespace: String, name: String) async throws -> [ResourceRow]
    /// Long-lived `kubectl port-forward <resource>/<name> local:remote`. Status
    /// lines arrive via `onLine`; `onEnd` fires when it stops (nil = clean/stopped).
    func portForward(context: String, namespace: String, resource: String, name: String,
                     localPort: Int, remotePort: Int,
                     onLine: @escaping @Sendable (String) -> Void,
                     onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess
    func topPod(context: String, namespace: String, name: String) async throws -> String
    /// In-container process list. `container` nil = kubectl's default (the first one, or
    /// the `kubectl.kubernetes.io/default-container` annotation).
    func podProcesses(context: String, namespace: String, name: String, container: String?) async throws -> String
    /// Full pod JSON (for the "Why" health/forensics report).
    func podDetail(context: String, namespace: String, name: String) async throws -> K8sPod
    /// Scrape a pod's Prometheus `/metrics` (raw text). Uses an ephemeral
    /// `port-forward` + local HTTP GET (the kubelet streaming path), which reaches
    /// pods on managed clusters where the API-server pod proxy can't.
    func podMetrics(context: String, namespace: String, pod: String, endpoint: MetricEndpoint) async throws -> String
    /// Prometheus-Operator monitors (cluster-wide, filtered later by their
    /// `namespaceSelector`) + the Services of `namespace`, for authoritative
    /// metrics-endpoint discovery. Best-effort — empty when the CRDs are absent.
    func metricsSources(context: String, namespace: String) async -> MetricsSources

    // Node detail (cluster-scoped — no namespace).
    func describeNode(context: String, name: String) async throws -> String
    func podsOnNode(context: String, node: String) async throws -> [ResourceRow]
    /// Map of node name → CPU architecture (amd64 / arm64 / …), so pods can show
    /// the arch of the node they run on. `get nodes -o json`, reduced client-side
    /// to name → arch (60s-TTL cached by the view model).
    func nodeArchitectures(context: String) async throws -> [String: String]
    func describeNamespace(context: String, name: String) async throws -> String
    /// All resource entities in a namespace (kind / name / age).
    func namespaceInventory(context: String, namespace: String) async throws -> [NamespaceResource]

    // Diagnostics (heap dump / async-profiler). `args` is the in-container command
    // after `--`; long ops pass a generous timeout. `container` must be the one whose
    // process list the PID came from — a sidecar pod has several PID namespaces.
    func exec(context: String, namespace: String, pod: String, container: String?, args: [String], timeoutSeconds: Int) async throws -> String
    func copyFromPod(context: String, namespace: String, pod: String, container: String?, remotePath: String, localPath: String) async throws
    func copyToPod(context: String, namespace: String, pod: String, container: String?, localPath: String, remotePath: String) async throws
}

/// The page shape of `get --raw <list>?limit=1`: only the list metadata matters.
private struct ListPage: Decodable {
    struct Meta: Decodable {
        let remainingItemCount: Int?
        let `continue`: String?
    }
    private struct Ignored: Decodable { init(from decoder: Decoder) throws {} }
    let metadata: Meta?
    private let items: [Ignored]?
    var itemCount: Int { items?.count ?? 0 }
}

struct KubectlClient: KubeService {
    private let kubectl: Kubectl
    /// Long diagnostics (exec/cp for heap dump & profiling) run on a separate gate
    /// so a multi-minute op can't starve the routine polling on `kubectl`.
    private let diag: Kubectl
    private let decoder = JSONDecoder()

    init(kubectl: Kubectl = Kubectl()) {
        self.kubectl = kubectl
        self.diag = Kubectl(gateLimit: 4)
    }

    func contexts() async throws -> (contexts: [ClusterContext], current: String?) {
        let data = try await kubectl.run(["config", "view", "-o", "json"])
        let cfg = try decoder.decode(KubeConfig.self, from: data)
        let current = cfg.currentContext
        let list = (cfg.contexts ?? []).map { entry in
            ClusterContext(
                name: entry.name,
                defaultNamespace: entry.context?.namespace,
                isCurrent: entry.name == current,
                isProduction: Self.looksProduction(entry.name),
                isLocal: Self.looksLocal(entry.name))
        }
        return (list, current)
    }

    // Bound read latency so a hung/unreachable cluster fails fast with an error.
    private static let readTimeout = "--request-timeout=15s"

    func resources(kind: ResourceKind, context: String) async throws -> [ResourceRow] {
        if kind == .nodes { return try await nodeRows(context: context) }
        if kind == .secrets { return try await secretRows(context: context) }
        let nsFlag = kind.isNamespaced ? ["-A"] : []   // -A is invalid for cluster-scoped kinds
        let data = try await kubectl.run(
            ["--context", context, "get", kind.kubectlResource] + nsFlag + ["-o", "json", Self.readTimeout],
            highPriority: true)   // the visible table — jump ahead of background counts
        switch kind {
        case .pods:
            return try decoder.decode(K8sList<K8sPod>.self, from: data).items.map(Derive.pod)
        case .deployments:
            return try decoder.decode(K8sList<K8sDeployment>.self, from: data).items.map(Derive.deployment)
        case .statefulSets:
            return try decoder.decode(K8sList<K8sStatefulSet>.self, from: data).items.map(Derive.statefulSet)
        case .replicaSets:
            return try decoder.decode(K8sList<K8sReplicaSet>.self, from: data).items.map(Derive.replicaSet)
        case .daemonSets:
            return try decoder.decode(K8sList<K8sDaemonSet>.self, from: data).items.map(Derive.daemonSet)
        case .configMaps:
            return try decoder.decode(K8sList<K8sConfigMap>.self, from: data).items.map(Derive.configMap)
        case .secrets:
            return []   // handled by secretRows above
        case .services:
            return try decoder.decode(K8sList<K8sService>.self, from: data).items.map(Derive.service)
        case .ingresses:
            return try decoder.decode(K8sList<K8sIngress>.self, from: data).items.map(Derive.ingress)
        case .persistentVolumeClaims:
            return try decoder.decode(K8sList<K8sPVC>.self, from: data).items.map(Derive.pvc)
        case .networkPolicies:
            return try decoder.decode(K8sList<K8sNetworkPolicy>.self, from: data).items.map(Derive.networkPolicy)
        case .endpoints:
            return try decoder.decode(K8sList<K8sEndpoints>.self, from: data).items.map(Derive.endpoints)
        case .persistentVolumes:
            return try decoder.decode(K8sList<K8sPV>.self, from: data).items.map(Derive.pv)
        case .storageClasses:
            return try decoder.decode(K8sList<K8sStorageClass>.self, from: data).items.map(Derive.storageClass)
        case .podDisruptionBudgets:
            return try decoder.decode(K8sList<K8sPDB>.self, from: data).items.map(Derive.pdb)
        case .jobs:
            return try decoder.decode(K8sList<K8sJob>.self, from: data).items.map(Derive.job)
        case .cronJobs:
            return try decoder.decode(K8sList<K8sCronJob>.self, from: data).items.map(Derive.cronJob)
        case .serviceAccounts:
            return try decoder.decode(K8sList<K8sServiceAccount>.self, from: data).items.map(Derive.serviceAccount)
        case .horizontalPodAutoscalers:
            return try decoder.decode(K8sList<K8sHPA>.self, from: data).items.map(Derive.hpa)
        case .events:
            return try decoder.decode(K8sList<K8sEvent>.self, from: data).items.map(Derive.event)
        case .namespaces:
            return try decoder.decode(K8sList<K8sNamespace>.self, from: data).items.map(Derive.namespace)
        case .nodes:
            return []   // handled by nodeRows above
        }
    }

    /// Secrets are read as a server-side Table (`get secrets --no-headers`): the API
    /// server answers with the printed cells plus PartialObjectMetadata and kubectl
    /// prints only the cells, so secret VALUES never reach this process — `-o json`
    /// would download every one of them just to count keys. (The metadata can still
    /// carry a `last-applied-configuration` annotation with values into kubectl's own
    /// memory; it never reaches stdout.) Columns: [NAMESPACE] NAME TYPE DATA AGE.
    /// `namespace` nil = all namespaces.
    private func secretRows(context: String, namespace: String? = nil) async throws -> [ResourceRow] {
        // `-A` is a flag of `get`, not a global one — it must follow the verb.
        let scope = namespace.map { ["-n", $0] } ?? ["-A"]
        let data = try await kubectl.run(
            ["--context", context, "get", "secrets"] + scope + ["--no-headers", Self.readTimeout],
            highPriority: true)
        let offset = namespace == nil ? 1 : 0
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ResourceRow? in
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard f.count >= 4 + offset, let keys = Int(f[2 + offset]) else { return nil }
                return ResourceRow(
                    kind: .secrets, namespace: namespace ?? f[0], name: f[offset],
                    statusText: "", statusKind: .neutral,
                    // The Table carries kubectl's humanized age, not creationTimestamp —
                    // good enough for the column and (approximately) for sorting.
                    cells: ["type": f[1 + offset], "keys": f[2 + offset], "age": f[3 + offset], "created": "—"],
                    sortValues: ["keys": Double(keys), "age": Self.humanizedSeconds(f[3 + offset])])
            }
    }

    /// Seconds in a kubectl humanized duration (`2y5d`, `13d`, `36h`, `5m30s`, `45s`).
    /// Approximate by construction; unknown text → 0.
    static func humanizedSeconds(_ text: String) -> Double {
        var total = 0.0, number = 0.0, sawDigit = false
        for ch in text {
            if let d = ch.wholeNumberValue { number = number * 10 + Double(d); sawDigit = true; continue }
            guard sawDigit else { continue }
            switch ch {
            case "y": total += number * 365 * 86400
            case "d": total += number * 86400
            case "h": total += number * 3600
            case "m": total += number * 60
            case "s": total += number
            default: break
            }
            number = 0; sawDigit = false
        }
        return total
    }

    /// `get nodes -o json` (status/age) merged with best-effort `top nodes` (usage).
    private func nodeRows(context: String) async throws -> [ResourceRow] {
        async let nodesData = kubectl.run(
            ["--context", context, "get", "nodes", "-o", "json", Self.readTimeout], highPriority: true)
        async let topResult = topNodesText(context: context)
        let nodes = try decoder.decode(K8sList<K8sNode>.self, from: await nodesData).items
        let usage = (try? await topResult).map(NodeUsage.parse) ?? [:]
        return nodes.map { Derive.node($0, usage: usage[$0.metadata.name]) }
    }

    func podDetail(context: String, namespace: String, name: String) async throws -> K8sPod {
        let data = try await kubectl.run(
            ["--context", context, "get", "pod", name, "-n", namespace, "-o", "json", Self.readTimeout],
            highPriority: true)   // detail pane — the user is waiting on it
        return try decoder.decode(K8sPod.self, from: data)
    }

    func nodeArchitectures(context: String) async throws -> [String: String] {
        let data = try await kubectl.run(
            ["--context", context, "get", "nodes", "-o", "json", Self.readTimeout])
        let nodes = try decoder.decode(K8sList<K8sNode>.self, from: data).items
        return Dictionary(uniqueKeysWithValues:
            nodes.compactMap { n in n.status?.nodeInfo?.architecture.map { (n.metadata.name, $0) } })
    }

    private func topNodesText(context: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "top", "nodes", "--no-headers", Self.readTimeout], highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func count(kind: ResourceKind, context: String) async throws -> Int {
        // `?limit=1` makes the API server answer one item plus `metadata.remainingItemCount`
        // (a consistent read from etcd), so a sidebar count costs ~2KB instead of every
        // object serialized — on a 300-pod cluster `-o name` still pulled 6MB per kind.
        // An answer served from the watch cache omits the field but keeps a continue
        // token; only then fall back to listing names.
        let data = try await kubectl.run(
            ["--context", context, "get", "--raw", "\(kind.apiPath)?limit=1", Self.readTimeout])
        if let page = try? decoder.decode(ListPage.self, from: data) {
            if let remaining = page.metadata?.remainingItemCount { return page.itemCount + remaining }
            if (page.metadata?.continue ?? "").isEmpty { return page.itemCount }   // the whole list fit in one page
        }
        let nsFlag = kind.isNamespaced ? ["-A"] : []   // -A is invalid for cluster-scoped kinds
        let names = try await kubectl.run(
            ["--context", context, "get", kind.kubectlResource] + nsFlag + ["-o", "name", Self.readTimeout])
        return String(decoding: names, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .count
    }

    func eventKeys(context: String) async throws -> Set<String> {
        let data = try await kubectl.run(
            ["--context", context, "get", "events", "-A", "-o", "name", Self.readTimeout])
        // `-o name` lines look like `event/<name>` — the identity is the last path component.
        return Set(String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { $0.split(separator: "/").last.map(String.init) })
    }

    // Mutations and detail-pane reads run high-priority: the user explicitly
    // asked for them and shouldn't queue behind a background counts burst.
    func delete(kind: ResourceKind, context: String, namespace: String, name: String) async throws {
        // --wait=false returns immediately; the row shows Terminating on the next poll.
        var args = ["--context", context]
        if !namespace.isEmpty { args += ["-n", namespace] }   // cluster-scoped kinds (PV) have none
        args += ["delete", kind.kubectlResource, name, "--wait=false"]
        _ = try await kubectl.run(args, highPriority: true)
    }

    func restart(kind: ResourceKind, context: String, namespace: String, name: String) async throws {
        _ = try await kubectl.run(
            ["--context", context, "-n", namespace, "rollout", "restart", "\(kind.kubectlResource)/\(name)"],
            highPriority: true)
    }

    func scale(kind: ResourceKind, context: String, namespace: String, name: String, replicas: Int) async throws {
        _ = try await kubectl.run(
            ["--context", context, "-n", namespace, "scale", "\(kind.kubectlResource)/\(name)", "--replicas=\(replicas)"],
            highPriority: true)
    }

    func rolloutHistory(kind: ResourceKind, context: String, namespace: String, name: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "rollout", "history", "\(kind.kubectlResource)/\(name)", Self.readTimeout],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func rollback(kind: ResourceKind, context: String, namespace: String, name: String, toRevision: Int?) async throws {
        var args = ["--context", context, "-n", namespace, "rollout", "undo", "\(kind.kubectlResource)/\(name)"]
        if let toRevision, toRevision > 0 { args.append("--to-revision=\(toRevision)") }
        _ = try await kubectl.run(args, highPriority: true)
    }

    func describe(kind: ResourceKind, context: String, namespace: String, name: String) async throws -> String {
        var args = ["--context", context]
        if !namespace.isEmpty { args += ["-n", namespace] }   // cluster-scoped kinds have no namespace
        args += ["describe", kind.singularName, name, Self.readTimeout]
        let data = try await kubectl.run(args, highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    // `--all-containers` opens one log request per container and kubectl refuses the
    // pod outright above its default of 5 — a pod with a few sidecars has more.
    private static let maxLogRequests = "--max-log-requests=50"

    func streamLogs(context: String, namespace: String, pod: String, container: String?, prefix: Bool,
                    onLine: @escaping @Sendable (String) -> Void,
                    onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess {
        var args = ["--context", context, "-n", namespace, "logs", pod,
                    "-f", "--tail=2000", "--timestamps"]
        if let container { args += ["-c", container] } else { args += ["--all-containers=true", Self.maxLogRequests] }
        if prefix && container == nil { args.append("--prefix") }
        return kubectl.stream(args, onLine: onLine, onEnd: onEnd)
    }

    func portForward(context: String, namespace: String, resource: String, name: String,
                     localPort: Int, remotePort: Int,
                     onLine: @escaping @Sendable (String) -> Void,
                     onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess {
        let args = ["--context", context, "-n", namespace, "port-forward",
                    "\(resource)/\(name)", "\(localPort):\(remotePort)"]
        return kubectl.stream(args, onLine: onLine, onEnd: onEnd)
    }

    func podMetrics(context: String, namespace: String, pod: String, endpoint: MetricEndpoint) async throws -> String {
        // Ephemeral port-forward with an auto-assigned local port (`:remote`) so we
        // never collide with a user session; kubectl prints the chosen local port.
        let ready = PortForwardReady()
        let handle = kubectl.stream(
            ["--context", context, "-n", namespace, "port-forward", "pod/\(pod)", ":\(endpoint.port)"],
            onLine: { ready.consume($0) },
            onEnd: { ready.finish($0) })
        do {
            let localPort = try await ready.waitForPort(timeout: 8)
            let text = try await Self.httpGet(port: localPort, path: endpoint.path)
            handle.stop()
            return text
        } catch {
            handle.stop()
            throw error
        }
    }

    /// Plain HTTP GET against the forwarded local port (10s timeout).
    private static func httpGet(port: Int, path: String) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw KubectlError(message: "bad metrics URL for \(path)", code: -1)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KubectlError(message: "HTTP \(http.statusCode) from \(path)", code: Int32(http.statusCode))
        }
        return String(decoding: data, as: UTF8.self)
    }

    func metricsSources(context: String, namespace: String) async -> MetricsSources {
        // Monitors are listed cluster-wide: the common kube-prometheus layout keeps them
        // in `monitoring` with a `namespaceSelector` — the pod's namespace is only one of
        // the places they live. Discovery filters them by that selector. Services stay
        // namespace-local (a ServiceMonitor can only pick Services in the selected namespaces).
        async let sm = optionalList(K8sServiceMonitor.self, context: context, namespace: nil, resource: "servicemonitors")
        async let pm = optionalList(K8sPodMonitor.self, context: context, namespace: nil, resource: "podmonitors")
        async let svc = optionalList(K8sService.self, context: context, namespace: namespace, resource: "services")
        return await MetricsSources(serviceMonitors: sm, podMonitors: pm, services: svc)
    }

    /// `get <resource> [-n <ns> | -A] -o json` decoded to `[T]`, swallowing all errors
    /// (missing CRD / no RBAC) → empty. For best-effort discovery inputs.
    private func optionalList<T: Decodable & Sendable>(_ type: T.Type, context: String, namespace: String?, resource: String) async -> [T] {
        let scope = namespace.map { ["-n", $0] } ?? ["-A"]   // after the verb: `-A` is a `get` flag
        guard let data = try? await kubectl.run(
            ["--context", context, "get", resource] + scope + ["-o", "json", Self.readTimeout],
            highPriority: true) else { return [] }   // feeds the Metrics tab the user opened
        return (try? decoder.decode(K8sList<T>.self, from: data))?.items ?? []
    }

    private static func eventSelector(kind: ResourceKind, name: String) -> String {
        "involvedObject.name=\(name),involvedObject.kind=\(kind.apiKind)"
    }

    func resourceEvents(kind: ResourceKind, context: String, namespace: String, name: String) async throws -> [ResourceRow] {
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "get", "events",
             "--field-selector", Self.eventSelector(kind: kind, name: name), "-o", "json", Self.readTimeout],
            highPriority: true)
        return try decoder.decode(K8sList<K8sEvent>.self, from: data).items.map(Derive.event)
    }

    func topPod(context: String, namespace: String, name: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "top", "pod", name, "--containers", Self.readTimeout],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func describeNode(context: String, name: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "describe", "node", name, Self.readTimeout],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func podsOnNode(context: String, node: String) async throws -> [ResourceRow] {
        let data = try await kubectl.run(
            ["--context", context, "get", "pods", "-A", "--field-selector", "spec.nodeName=\(node)",
             "-o", "json", Self.readTimeout],
            highPriority: true)
        return try decoder.decode(K8sList<K8sPod>.self, from: data).items.map(Derive.pod)
    }

    func describeNamespace(context: String, name: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "describe", "namespace", name, Self.readTimeout],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func namespaceInventory(context: String, namespace: String) async throws -> [NamespaceResource] {
        // One JSON query for many kinds (each item carries its own `kind`), plus the
        // secrets as a Table so their values never reach this process. Secrets are
        // best-effort: RBAC often allows listing pods but not secrets.
        async let secretsTask = try? secretRows(context: context, namespace: namespace)
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "get", NamespaceInventory.query, "-o", "json", Self.readTimeout],
            highPriority: true)
        var items = try decoder.decode(K8sList<K8sObject>.self, from: data).items.map { obj in
            let age = Age.stamp(obj.metadata.creationTimestamp)
            return NamespaceResource(
                kind: obj.kind.flatMap { NamespaceInventory.kindByApiKind[$0] },
                kindLabel: obj.kind ?? "?",
                name: obj.metadata.name,
                age: age.text,
                ageSeconds: age.seconds)
        }
        for row in await secretsTask ?? [] {
            items.append(NamespaceResource(kind: .secrets, kindLabel: "Secret", name: row.name,
                                           age: row.value("age"), ageSeconds: row.sortValues["age"] ?? 0))
        }
        return items
    }

    private static func containerFlag(_ container: String?) -> [String] {
        container.map { ["-c", $0] } ?? []
    }

    func podProcesses(context: String, namespace: String, name: String, container: String?) async throws -> String {
        // Read-only process listing inside the container; falls back across procps/busybox.
        // procps `top` needs `-w` (else it truncates rows at 80 columns without a tty) and
        // `-c` (full command lines); busybox rejects `-w` and takes the plain form.
        // NOTE: `--request-timeout` does NOT bound an exec session (verified: a 3s timeout
        // let `sleep 7` finish) — `Kubectl.run`'s 30s `timeout:` watchdog is what frees
        // the slot if the exec hangs.
        let script = "top -bn1 -w512 -c 2>/dev/null || top -bn1 2>/dev/null || ps aux 2>/dev/null || ps -ef 2>/dev/null || echo 'no top/ps in container'"
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "exec", name] + Self.containerFlag(container) + ["--",
             "/bin/sh", "-c", script],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    // Long diagnostics run on `diag` (separate gate). `--request-timeout` does not cap a
    // streaming exec/cp session, so each call's `timeout:` (the SIGTERM/SIGKILL watchdog
    // in `Kubectl.run`) is the real bound; `--retries` keeps a flaky cp finite.
    private static let copyRetries = "--retries=3"
    private static let copyWatchdog: TimeInterval = 1260

    func exec(context: String, namespace: String, pod: String, container: String?, args: [String], timeoutSeconds: Int) async throws -> String {
        let data = try await diag.run(
            ["--context", context, "-n", namespace, "exec", pod] + Self.containerFlag(container) + ["--"] + args,
            timeout: TimeInterval(timeoutSeconds) + 60)   // watchdog: the op's own budget + margin
        return String(decoding: data, as: UTF8.self)
    }

    func copyFromPod(context: String, namespace: String, pod: String, container: String?, remotePath: String, localPath: String) async throws {
        _ = try await diag.run(
            ["--context", context, "cp", Self.copyRetries] + Self.containerFlag(container)
                + ["\(namespace)/\(pod):\(remotePath)", localPath],
            timeout: Self.copyWatchdog)
    }

    func copyToPod(context: String, namespace: String, pod: String, container: String?, localPath: String, remotePath: String) async throws {
        _ = try await diag.run(
            ["--context", context, "cp", Self.copyRetries] + Self.containerFlag(container)
                + [localPath, "\(namespace)/\(pod):\(remotePath)"],
            timeout: Self.copyWatchdog)
    }

    // MARK: - Context heuristics

    private static let localTokens = ["minikube", "docker-desktop", "docker-for-desktop",
                                      "kind-", "k3d-", "colima", "orbstack", "rancher-desktop",
                                      "localhost", "127.0.0.1"]

    static func looksLocal(_ name: String) -> Bool {
        let n = name.lowercased()
        return localTokens.contains { n.contains($0) }
    }

    static func looksProduction(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("non-prod") || n.contains("nonprod") { return false }
        return n.contains("prod") || n.contains("prd")
    }
}
