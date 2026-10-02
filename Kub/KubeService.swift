import Foundation

/// Abstraction over the cluster data source. Backed by `kubectl` today; can be
/// swapped for a native API client later without touching the UI/view-model.
protocol KubeService: Sendable {
    func contexts() async throws -> (contexts: [ClusterContext], current: String?)
    /// All resources of `kind` across every namespace of the context.
    func resources(kind: ResourceKind, context: String) async throws -> [ResourceRow]
    /// Lightweight element count for `kind` (names only — for sidebar counters).
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
    func logs(context: String, namespace: String, name: String) async throws -> String
    /// Follow a pod's logs (`logs -f`). Lines arrive via `onLine` (off-main); the
    /// stream ends with `onEnd` (nil = clean/stopped). Returns a stoppable handle.
    func streamLogs(context: String, namespace: String, pod: String, container: String?,
                    onLine: @escaping @Sendable (String) -> Void,
                    onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess
    func events(context: String, namespace: String, name: String) async throws -> String
    func resourceEvents(context: String, namespace: String, name: String) async throws -> [ResourceRow]
    /// Long-lived `kubectl port-forward <resource>/<name> local:remote`. Status
    /// lines arrive via `onLine`; `onEnd` fires when it stops (nil = clean/stopped).
    func portForward(context: String, namespace: String, resource: String, name: String,
                     localPort: Int, remotePort: Int,
                     onLine: @escaping @Sendable (String) -> Void,
                     onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess
    func topPod(context: String, namespace: String, name: String) async throws -> String
    func podProcesses(context: String, namespace: String, name: String) async throws -> String
    /// Full pod JSON (for the "Why" health/forensics report).
    func podDetail(context: String, namespace: String, name: String) async throws -> K8sPod
    /// Scrape a pod's Prometheus `/metrics` (raw text). Uses an ephemeral
    /// `port-forward` + local HTTP GET (the kubelet streaming path), which reaches
    /// pods on managed clusters where the API-server pod proxy can't.
    func podMetrics(context: String, namespace: String, pod: String, endpoint: MetricEndpoint) async throws -> String
    /// Prometheus-Operator monitors + Services in a namespace (for authoritative
    /// metrics-endpoint discovery). Best-effort — empty when the CRDs are absent.
    func metricsSources(context: String, namespace: String) async -> MetricsSources

    // Node detail (cluster-scoped — no namespace).
    func describeNode(context: String, name: String) async throws -> String
    func podsOnNode(context: String, node: String) async throws -> [ResourceRow]
    /// Map of node name → CPU architecture (amd64 / arm64 / …), so pods can show
    /// the arch of the node they run on. Cheap `get nodes -o json` projection.
    func nodeArchitectures(context: String) async throws -> [String: String]
    func describeNamespace(context: String, name: String) async throws -> String
    /// All resource entities in a namespace (kind / name / age).
    func namespaceInventory(context: String, namespace: String) async throws -> [NamespaceResource]

    // Diagnostics (heap dump / async-profiler). `args` is the in-container command
    // after `--`; long ops pass a generous timeout.
    func exec(context: String, namespace: String, pod: String, args: [String], timeoutSeconds: Int) async throws -> String
    func copyFromPod(context: String, namespace: String, pod: String, remotePath: String, localPath: String) async throws
    func copyToPod(context: String, namespace: String, pod: String, localPath: String, remotePath: String) async throws
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
            return try decoder.decode(K8sList<K8sSecret>.self, from: data).items.map(Derive.secret)
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
        let nsFlag = kind.isNamespaced ? ["-A"] : []   // -A is invalid for cluster-scoped kinds
        let data = try await kubectl.run(
            ["--context", context, "get", kind.kubectlResource] + nsFlag + ["-o", "name", Self.readTimeout])
        return String(decoding: data, as: UTF8.self)
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

    func logs(context: String, namespace: String, name: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "logs", name,
             "--tail=1000", "--all-containers=true", "--timestamps",
             "--request-timeout=20s"],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func streamLogs(context: String, namespace: String, pod: String, container: String?,
                    onLine: @escaping @Sendable (String) -> Void,
                    onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess {
        var args = ["--context", context, "-n", namespace, "logs", pod,
                    "-f", "--tail=2000", "--timestamps"]
        if let container { args += ["-c", container] } else { args.append("--all-containers=true") }
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
        async let sm = optionalList(K8sServiceMonitor.self, context: context, namespace: namespace, resource: "servicemonitors")
        async let pm = optionalList(K8sPodMonitor.self, context: context, namespace: namespace, resource: "podmonitors")
        async let svc = optionalList(K8sService.self, context: context, namespace: namespace, resource: "services")
        return await MetricsSources(serviceMonitors: sm, podMonitors: pm, services: svc)
    }

    /// `get <resource> -n <ns> -o json` decoded to `[T]`, swallowing all errors
    /// (missing CRD / no RBAC) → empty. For best-effort discovery inputs.
    private func optionalList<T: Decodable & Sendable>(_ type: T.Type, context: String, namespace: String, resource: String) async -> [T] {
        guard let data = try? await kubectl.run(
            ["--context", context, "-n", namespace, "get", resource, "-o", "json", Self.readTimeout],
            highPriority: true) else { return [] }   // feeds the Metrics tab the user opened
        return (try? JSONDecoder().decode(K8sList<T>.self, from: data))?.items ?? []
    }

    func events(context: String, namespace: String, name: String) async throws -> String {
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "get", "events",
             "--field-selector", "involvedObject.name=\(name)",
             "--sort-by=.lastTimestamp", Self.readTimeout],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    func resourceEvents(context: String, namespace: String, name: String) async throws -> [ResourceRow] {
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "get", "events",
             "--field-selector", "involvedObject.name=\(name)", "-o", "json", Self.readTimeout],
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
        // One query for many kinds; each item carries its own `kind`.
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, "get", NamespaceInventory.query, "-o", "json", Self.readTimeout],
            highPriority: true)
        return try decoder.decode(K8sList<K8sObject>.self, from: data).items.map { obj in
            NamespaceResource(
                kind: obj.kind.flatMap { NamespaceInventory.kindByApiKind[$0] },
                kindLabel: obj.kind ?? "?",
                name: obj.metadata.name,
                age: Age.format(obj.metadata.creationTimestamp),
                ageSeconds: Age.seconds(obj.metadata.creationTimestamp))
        }
    }

    func podProcesses(context: String, namespace: String, name: String) async throws -> String {
        // Read-only process listing inside the container; falls back across busybox/procps.
        // readTimeout bounds connection setup (before "--", so it's a kubectl flag, not
        // a shell arg) — without it a slow/hung exec holds a gate slot indefinitely.
        let script = "top -bn1 2>/dev/null || ps aux 2>/dev/null || ps -ef 2>/dev/null || echo 'no top/ps in container'"
        let data = try await kubectl.run(
            ["--context", context, "-n", namespace, Self.readTimeout, "exec", name, "--",
             "/bin/sh", "-c", script],
            highPriority: true)
        return String(decoding: data, as: UTF8.self)
    }

    // Long diagnostics run on `diag` (separate gate). cp is bounded by a generous
    // request-timeout and finite retries so a stalled transfer can't wedge a slot.
    private static let copyTimeout = "--request-timeout=1200s"
    private static let copyRetries = "--retries=3"

    func exec(context: String, namespace: String, pod: String, args: [String], timeoutSeconds: Int) async throws -> String {
        // request-timeout before "exec" so it's parsed by kubectl; long ops (profiling,
        // big heap dumps) need a generous bound rather than the 15s read timeout.
        let data = try await diag.run(
            ["--context", context, "-n", namespace, "--request-timeout=\(timeoutSeconds)s", "exec", pod, "--"] + args,
            timeout: TimeInterval(timeoutSeconds) + 60)   // watchdog: past the request-timeout
        return String(decoding: data, as: UTF8.self)
    }

    func copyFromPod(context: String, namespace: String, pod: String, remotePath: String, localPath: String) async throws {
        _ = try await diag.run(
            ["--context", context, Self.copyTimeout, "cp", Self.copyRetries, "\(namespace)/\(pod):\(remotePath)", localPath],
            timeout: 1260)   // matches copyTimeout (1200s) + margin
    }

    func copyToPod(context: String, namespace: String, pod: String, localPath: String, remotePath: String) async throws {
        _ = try await diag.run(
            ["--context", context, Self.copyTimeout, "cp", Self.copyRetries, localPath, "\(namespace)/\(pod):\(remotePath)"],
            timeout: 1260)
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
