import AppKit

// MARK: - Status kind → visual mapping

/// Coarse status bucket used to pick an SF Symbol + tint across all resource kinds.
enum StatusKind: Sendable {
    case healthy
    case pending
    case warning
    case error
    case terminating
    case completed
    case unknown
    case neutral   // resources without a health concept (config/secret) → kind icon

    var symbolName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        case .terminating: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle"
        case .unknown: return "questionmark.circle"
        case .neutral: return "circle"
        }
    }

    var color: NSColor {
        switch self {
        case .healthy: return .systemGreen
        case .pending: return .systemBlue
        case .warning: return .systemYellow
        case .error: return .systemRed
        case .terminating: return .systemOrange
        case .completed: return .secondaryLabelColor
        case .unknown: return .tertiaryLabelColor
        case .neutral: return .secondaryLabelColor
        }
    }
}

// MARK: - Cluster context

struct ClusterContext: Sendable, Hashable {
    let name: String
    let defaultNamespace: String?
    let isCurrent: Bool
    let isProduction: Bool
    let isLocal: Bool

    var displayName: String {
        if name.contains("/"), let last = name.split(separator: "/").last {
            return String(last)
        }
        return name
    }
}

// MARK: - Resource kinds

enum PrimaryAction: Sendable {
    case delete
    case restart

    var title: String { self == .delete ? "Delete" : "Restart" }
}

/// A column in the resource table. `id` doubles as the lookup key into `ResourceRow.value`.
struct ResourceColumn: Sendable {
    enum Style: Sendable {
        case status      // SF Symbol (from row.statusKind) + namespace text
        case statusText  // colored status word
        case plain       // plain text (name)
        case mono        // monospaced-digit numeric column
        case badge       // small colored capsule (e.g. node architecture)
    }
    let id: String
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    let style: Style
}

/// The resource types the sidebar can switch between.
enum ResourceKind: String, CaseIterable, Sendable {
    // Workloads
    case pods, deployments, statefulSets, replicaSets, daemonSets
    // Config
    case configMaps, secrets, serviceAccounts
    // Network
    case services, ingresses, networkPolicies, endpoints
    // Storage
    case persistentVolumeClaims, persistentVolumes, storageClasses
    // Jobs
    case jobs, cronJobs
    // Scaling / availability
    case horizontalPodAutoscalers, podDisruptionBudgets
    // Cluster
    case nodes, events, namespaces

    /// Sidebar section index — a thin divider is drawn where this changes.
    var section: Int {
        switch self {
        case .pods, .deployments, .statefulSets, .replicaSets, .daemonSets: return 0
        case .configMaps, .secrets, .serviceAccounts: return 1
        case .services, .ingresses, .networkPolicies, .endpoints: return 2
        case .persistentVolumeClaims, .persistentVolumes, .storageClasses: return 3
        case .jobs, .cronJobs: return 4
        case .horizontalPodAutoscalers, .podDisruptionBudgets: return 5
        case .nodes, .events, .namespaces: return 6
        }
    }

    /// Cluster-scoped kinds have no namespace — never grouped by it, and `-A` is
    /// invalid for them.
    var isNamespaced: Bool {
        switch self {
        case .nodes, .namespaces, .persistentVolumes, .storageClasses: return false
        default: return true
        }
    }

    /// Workloads whose replica count can be set via `kubectl scale`.
    var scalable: Bool {
        switch self {
        case .deployments, .statefulSets: return true
        default: return false
        }
    }

    /// Controllers that support `kubectl rollout history` / `rollout undo`.
    var rollbackable: Bool {
        switch self {
        case .deployments, .statefulSets, .daemonSets: return true
        default: return false
        }
    }

    /// Whether the UI groups rows under namespace headers. Events read better as a
    /// flat newest-first stream; nodes/namespaces have no namespace.
    var groupsByNamespace: Bool {
        switch self {
        case .nodes, .events, .namespaces, .persistentVolumes, .storageClasses: return false
        default: return true
        }
    }

    /// Default column sort applied when the kind is shown (nil → by name).
    var defaultSort: (column: String, ascending: Bool)? {
        switch self {
        case .events: return ("age", true)   // smallest age = most recent → newest first
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .pods: return "Pods"
        case .deployments: return "Deployments"
        case .statefulSets: return "StatefulSets"
        case .replicaSets: return "ReplicaSets"
        case .daemonSets: return "DaemonSets"
        case .configMaps: return "ConfigMaps"
        case .secrets: return "Secrets"
        case .services: return "Services"
        case .ingresses: return "Ingresses"
        case .persistentVolumeClaims: return "PVCs"
        case .jobs: return "Jobs"
        case .cronJobs: return "CronJobs"
        case .serviceAccounts: return "ServiceAccounts"
        case .horizontalPodAutoscalers: return "HPAs"
        case .nodes: return "Nodes"
        case .events: return "Events"
        case .namespaces: return "Namespaces"
        case .networkPolicies: return "NetworkPolicies"
        case .endpoints: return "Endpoints"
        case .persistentVolumes: return "PVs"
        case .storageClasses: return "StorageClasses"
        case .podDisruptionBudgets: return "PDBs"
        }
    }

    /// Singular, lowercase — used in kubectl commands and dialog text.
    var singularName: String {
        switch self {
        case .pods: return "pod"
        case .deployments: return "deployment"
        case .statefulSets: return "statefulset"
        case .replicaSets: return "replicaset"
        case .daemonSets: return "daemonset"
        case .configMaps: return "configmap"
        case .secrets: return "secret"
        case .services: return "service"
        case .ingresses: return "ingress"
        case .persistentVolumeClaims: return "pvc"
        case .jobs: return "job"
        case .cronJobs: return "cronjob"
        case .serviceAccounts: return "serviceaccount"
        case .horizontalPodAutoscalers: return "hpa"
        case .nodes: return "node"
        case .events: return "event"
        case .namespaces: return "namespace"
        case .networkPolicies: return "networkpolicy"
        case .endpoints: return "endpoints"
        case .persistentVolumes: return "persistentvolume"
        case .storageClasses: return "storageclass"
        case .podDisruptionBudgets: return "poddisruptionbudget"
        }
    }

    var kubectlResource: String {
        switch self {
        case .pods: return "pods"
        case .deployments: return "deployments"
        case .statefulSets: return "statefulsets"
        case .replicaSets: return "replicasets"
        case .daemonSets: return "daemonsets"
        case .configMaps: return "configmaps"
        case .secrets: return "secrets"
        case .services: return "services"
        case .ingresses: return "ingresses"
        case .persistentVolumeClaims: return "persistentvolumeclaims"
        case .jobs: return "jobs"
        case .cronJobs: return "cronjobs"
        case .serviceAccounts: return "serviceaccounts"
        case .horizontalPodAutoscalers: return "horizontalpodautoscalers"
        case .nodes: return "nodes"
        case .events: return "events"
        case .namespaces: return "namespaces"
        case .networkPolicies: return "networkpolicies"
        case .endpoints: return "endpoints"
        case .persistentVolumes: return "persistentvolumes"
        case .storageClasses: return "storageclasses"
        case .podDisruptionBudgets: return "poddisruptionbudgets"
        }
    }

    var symbol: String {
        switch self {
        case .pods: return "cube"
        case .deployments: return "square.stack.3d.up"
        case .statefulSets: return "cylinder.split.1x2"
        case .replicaSets: return "square.on.square"
        case .daemonSets: return "square.grid.3x3"
        case .configMaps: return "doc.text"
        case .secrets: return "key.fill"
        case .services: return "network"
        case .ingresses: return "globe"
        case .persistentVolumeClaims: return "externaldrive.fill"
        case .jobs: return "list.bullet.rectangle"
        case .cronJobs: return "clock.arrow.circlepath"
        case .serviceAccounts: return "person.circle"
        case .horizontalPodAutoscalers: return "chart.line.uptrend.xyaxis"
        case .nodes: return "server.rack"
        case .events: return "bell"
        case .namespaces: return "square.stack.3d.down.right"
        case .networkPolicies: return "lock.shield"
        case .endpoints: return "point.3.connected.trianglepath.dotted"
        case .persistentVolumes: return "externaldrive"
        case .storageClasses: return "internaldrive"
        case .podDisruptionBudgets: return "shield.lefthalf.filled"
        }
    }

    /// nil → read-only kind (no row action).
    var primaryAction: PrimaryAction? {
        switch self {
        case .pods, .replicaSets, .jobs, .configMaps, .secrets,
             .services, .ingresses, .cronJobs, .horizontalPodAutoscalers, .podDisruptionBudgets,
             .persistentVolumeClaims, .persistentVolumes, .networkPolicies, .serviceAccounts: return .delete
        case .deployments, .statefulSets, .daemonSets: return .restart
        // Cluster infra / auto-managed / catastrophic-cascade → never a one-click delete.
        case .nodes, .events, .namespaces, .endpoints, .storageClasses: return nil
        }
    }

    /// Deletes that can destroy real data — a PVC/PV can cascade to the backing
    /// disk (reclaim policy Delete) — demand typing the name to confirm.
    var requiresTypedDeleteConfirmation: Bool {
        switch self {
        case .persistentVolumeClaims, .persistentVolumes: return true
        default: return false
        }
    }

    /// Data columns for a row. The namespace is rendered as a group header, so
    /// the status icon lives on the name column instead of a separate namespace one.
    var columns: [ResourceColumn] {
        let status = ResourceColumn(id: "status", title: "Status", width: 150, minWidth: 104, style: .statusText)
        let age = ResourceColumn(id: "age", title: "Age", width: 64, minWidth: 48, style: .mono)
        func name(_ title: String) -> ResourceColumn {
            ResourceColumn(id: "name", title: title, width: 260, minWidth: 150, style: .status)
        }
        func mono(_ id: String, _ title: String, _ w: CGFloat, _ mw: CGFloat) -> ResourceColumn {
            ResourceColumn(id: id, title: title, width: w, minWidth: mw, style: .mono)
        }
        func plain(_ id: String, _ title: String, _ w: CGFloat, _ mw: CGFloat) -> ResourceColumn {
            ResourceColumn(id: id, title: title, width: w, minWidth: mw, style: .plain)
        }
        switch self {
        case .pods:
            return [name("Pod"), status,
                    mono("ready", "Ready", 54, 46), mono("restarts", "Restarts", 68, 56),
                    mono("cpu", "CPU req", 78, 60), mono("mem", "Mem req", 84, 64),
                    ResourceColumn(id: "arch", title: "Arch", width: 82, minWidth: 82, style: .badge), age]
        case .deployments:
            return [name("Deployment"), status,
                    mono("ready", "Ready", 54, 46), mono("uptodate", "Up-to-date", 88, 70),
                    mono("available", "Available", 78, 60), age]
        case .statefulSets:
            return [name("StatefulSet"), status,
                    mono("ready", "Ready", 54, 46), mono("uptodate", "Up-to-date", 88, 70), age]
        case .replicaSets:
            return [name("ReplicaSet"), status,
                    mono("desired", "Desired", 64, 52), mono("current", "Current", 64, 52),
                    mono("ready", "Ready", 54, 46), age]
        case .daemonSets:
            return [name("DaemonSet"), status,
                    mono("desired", "Desired", 64, 52), mono("current", "Current", 64, 52),
                    mono("ready", "Ready", 54, 46), mono("uptodate", "Up-to-date", 88, 70),
                    mono("available", "Available", 78, 60), age]
        case .configMaps:
            return [name("ConfigMap"), mono("keys", "Keys", 56, 48), age]
        case .secrets:
            return [name("Secret"), plain("type", "Type", 200, 120), mono("keys", "Keys", 56, 48), age]
        case .services:
            return [name("Service"), plain("type", "Type", 110, 80),
                    plain("clusterIP", "Cluster IP", 120, 90), plain("ports", "Ports", 150, 90), age]
        case .ingresses:
            return [name("Ingress"), plain("hosts", "Hosts", 240, 120),
                    plain("address", "Address", 180, 120), age]
        case .persistentVolumeClaims:
            return [name("PVC"), status, plain("capacity", "Capacity", 90, 70),
                    plain("storageClass", "StorageClass", 150, 100), age]
        case .jobs:
            return [name("Job"), status, mono("completions", "Completions", 90, 72),
                    plain("duration", "Duration", 90, 70), age]
        case .cronJobs:
            return [name("CronJob"), plain("schedule", "Schedule", 130, 90),
                    plain("suspend", "Suspend", 80, 60), plain("lastRun", "Last Run", 90, 70), age]
        case .serviceAccounts:
            return [name("ServiceAccount"), mono("secrets", "Secrets", 64, 50), age]
        case .horizontalPodAutoscalers:
            return [name("HPA"), mono("min", "Min", 50, 44), mono("max", "Max", 50, 44),
                    plain("replicas", "Replicas", 80, 60), age]
        case .nodes:
            return [name("Node"), status,
                    ResourceColumn(id: "arch", title: "Arch", width: 82, minWidth: 82, style: .badge),
                    mono("cpu", "CPU", 72, 56), mono("cpupct", "CPU%", 62, 50),
                    mono("mem", "Mem", 84, 64), mono("mempct", "Mem%", 62, 50), age]
        case .events:
            // Time-first stream; namespace is included here (so it isn't auto-inserted first).
            return [ResourceColumn(id: "age", title: "Time", width: 120, minWidth: 84, style: .plain),
                    name("Reason"),
                    plain("object", "Object", 200, 120),
                    plain("namespace", "Namespace", 150, 100),
                    plain("message", "Message", 340, 140),
                    mono("count", "Count", 56, 46)]
        case .namespaces:
            return [name("Namespace"), status, age]
        case .networkPolicies:
            return [name("NetworkPolicy"), plain("podSelector", "Pod Selector", 220, 120),
                    plain("policyTypes", "Policy Types", 130, 90), age]
        case .endpoints:
            return [name("Endpoints"), plain("endpoints", "Endpoints", 300, 140),
                    mono("count", "Count", 56, 46), age]
        case .persistentVolumes:
            return [name("PV"), status, plain("capacity", "Capacity", 90, 70),
                    plain("accessModes", "Access", 84, 64), plain("reclaim", "Reclaim", 90, 70),
                    plain("storageClass", "StorageClass", 140, 100), plain("claim", "Claim", 200, 130), age]
        case .storageClasses:
            return [name("StorageClass"), plain("provisioner", "Provisioner", 220, 120),
                    plain("reclaim", "Reclaim", 90, 70), plain("binding", "Binding Mode", 120, 90),
                    plain("default", "Default", 70, 56), age]
        case .podDisruptionBudgets:
            return [name("PDB"), status, plain("minAvailable", "Min Avail", 84, 64),
                    plain("maxUnavailable", "Max Unavail", 96, 72), mono("allowed", "Allowed", 72, 56), age]
        }
    }
}

// MARK: - A single table row, kind-agnostic

struct ResourceRow: Sendable, Hashable {
    let kind: ResourceKind
    let namespace: String
    let name: String
    let statusText: String
    let statusKind: StatusKind
    var cells: [String: String]    // columnId → display value (mutable: pods get arch enriched from node data)
    let sortValues: [String: Double] // columnId → numeric value for sorting
    /// Explicit unique identity when name isn't unique (events: name = reason, so
    /// this carries the real metadata.name). nil → fall back to namespace/name.
    var uid: String? = nil

    /// Stable identity for preserving selection across refresh/filter.
    var key: String { uid ?? "\(namespace)/\(name)" }

    func value(_ columnId: String) -> String {
        switch columnId {
        case "namespace": return namespace
        case "name": return name
        case "status": return statusText
        default: return cells[columnId] ?? "—"
        }
    }

    /// Compare against another row for a given column (numeric where possible).
    func compare(to other: ResourceRow, column: String) -> ComparisonResult {
        if let a = sortValues[column], let b = other.sortValues[column] {
            return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        return value(column).localizedCaseInsensitiveCompare(other.value(column))
    }

    var isSystemNamespace: Bool { namespace.hasPrefix("kube-") }

    /// The namespace this row belongs to for pin/bookmark purposes. For the
    /// Namespaces kind the row *is* a namespace (its name); namespaced kinds use
    /// their namespace; other cluster-scoped kinds have none (nil → no pin action,
    /// and never filtered out by the bookmark toggle).
    var pinnableNamespace: String? {
        if kind == .namespaces { return name }
        return namespace.isEmpty ? nil : namespace
    }
}

// MARK: - Grouping

/// A dimension the resource table can group rows by (Finder-style "Group by").
/// The flat, ungrouped state is the toolbar toggle, not a case here.
enum GroupBy: String, CaseIterable, Sendable {
    case namespace, status, node, workload

    var title: String {
        switch self {
        case .namespace: return "Namespace"
        case .status:    return "Status"
        case .node:      return "Node"
        case .workload:  return "Workload"
        }
    }

    /// The group a row falls into — its header text ("—" when the field is empty).
    func key(for row: ResourceRow) -> String {
        let value: String
        switch self {
        case .namespace: value = row.namespace
        case .status:    value = row.statusText
        case .node:      value = row.cells["nodeName"] ?? ""
        case .workload:  value = row.cells["controlledBy"] ?? ""
        }
        return value.isEmpty ? "—" : value
    }
}

extension ResourceKind {
    /// Group-by dimensions offered for this kind (flat is the toolbar toggle, not here).
    var groupings: [GroupBy] {
        var g: [GroupBy] = []
        if groupsByNamespace { g.append(.namespace) }   // events/nodes/ns read flat, not by ns
        if columns.contains(where: { $0.style == .statusText }) { g.append(.status) }
        if self == .pods { g.append(contentsOf: [.node, .workload]) }
        return g
    }

    /// Grouping applied by default (nil = flat) — namespace where it makes sense.
    var defaultGrouping: GroupBy? { groupsByNamespace ? .namespace : nil }
}

// MARK: - Detail panel

enum DetailSection: Int, CaseIterable, Sendable {
    case overview, health, containers, mounts, history, logs, shell, events, top, pods, resources, metrics
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .health: return "Why"
        case .containers: return "Containers"
        case .mounts: return "Mounts"
        case .history: return "History"
        case .logs: return "Logs"
        case .shell: return "Shell"
        case .events: return "Events"
        case .top: return "Top"
        case .pods: return "Pods"
        case .resources: return "Resources"
        case .metrics: return "Metrics"
        }
    }
}

extension ResourceKind {
    /// Which detail tabs make sense for this kind. Single-element → no switcher.
    var detailSections: [DetailSection] {
        switch self {
        case .pods: return [.overview, .health, .containers, .mounts, .logs, .shell, .events, .metrics, .top]
        case .deployments, .statefulSets, .daemonSets: return [.overview, .history, .events]
        case .nodes: return [.overview, .pods]
        case .namespaces: return [.overview, .resources]
        case .events: return [.overview]
        case .configMaps, .secrets, .serviceAccounts: return [.overview]
        case .persistentVolumes, .storageClasses: return [.overview]   // cluster-scoped
        default: return [.overview, .events]
        }
    }
}
