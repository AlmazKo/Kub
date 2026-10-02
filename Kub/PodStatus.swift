import Foundation

// MARK: - Age formatting (kubectl-like compact durations)

enum Age {
    static func parse(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    static func format(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = parse(iso) else { return "—" }
        return humanize(max(0, now.timeIntervalSince(date)))
    }

    /// Age in seconds (for sorting). 0 if unparseable.
    static func seconds(_ iso: String?, now: Date = Date()) -> Double {
        guard let iso, let date = parse(iso) else { return 0 }
        return max(0, now.timeIntervalSince(date))
    }

    /// Absolute local timestamp: "HH:mm:ss" if it's today, "MMM d  HH:mm:ss"
    /// otherwise (so older events carry the day).
    static func timestamp(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = parse(iso) else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now)
            ? "HH:mm:ss"
            : "MMM d  HH:mm:ss"
        return formatter.string(from: date)
    }

    static func humanize(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return h < 10 ? "\(h)h\(m % 60)m" : "\(h)h" }
        let d = h / 24
        if d < 365 { return d < 8 ? "\(d)d\(h % 24)h" : "\(d)d" }
        let y = d / 365
        return y < 8 ? "\(y)y\(d % 365)d" : "\(y)y"
    }

    /// Absolute creation date-time (local, to the second) for the age column's
    /// hover tooltip — e.g. "Jul 3, 2026  07:13:28". "—" if unparseable.
    static func absolute(_ iso: String?) -> String {
        guard let iso, let date = parse(iso) else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy  HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - Kubernetes resource quantities

/// Minimal parser for the Kubernetes quantity strings used in resource requests
/// (e.g. "100m", "1", "128Mi", "1Gi"). Enough for summing and display.
enum Quantity {
    static func cpuMillicores(_ s: String) -> Double? {
        if s.hasSuffix("m") { return Double(s.dropLast()) }
        if let v = Double(s) { return v * 1000 }
        return nil
    }

    static func memoryBytes(_ s: String) -> Double? {
        let units: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1048576), ("Gi", 1073741824),
            ("Ti", 1099511627776), ("Pi", 1125899906842624),
            ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15),
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            if let v = Double(s.dropLast(suffix.count)) { return v * mult }
        }
        return Double(s)
    }

    static func formatCPU(_ millicores: Double) -> String {
        guard millicores > 0 else { return "—" }
        if millicores < 1000 { return "\(Int(millicores.rounded()))m" }
        return trim(millicores / 1000)
    }

    static func formatMemory(_ bytes: Double) -> String {
        guard bytes > 0 else { return "—" }
        let mi = bytes / 1048576
        if mi < 1024 { return "\(Int(mi.rounded()))Mi" }
        return trim(bytes / 1073741824) + "Gi"
    }

    private static func trim(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}

// MARK: - Row builders (kind → ResourceRow)

enum Derive {
    static func pod(_ pod: K8sPod) -> ResourceRow {
        let (text, kind) = PodStatusDerivation.derive(pod)
        let req = PodStatusDerivation.requestedResources(pod)
        let restarts = PodStatusDerivation.restartCount(pod)
        return ResourceRow(
            kind: .pods,
            namespace: pod.metadata.namespace ?? "",
            name: pod.metadata.name,
            statusText: text,
            statusKind: kind,
            cells: [
                "ready": PodStatusDerivation.readyString(pod),
                "restarts": "\(restarts)",
                "cpu": req.cpu,
                "mem": req.memory,
                "nodeName": pod.spec?.nodeName ?? "",   // not a column; joined to node arch by the view model
                "controlledBy": PodStatusDerivation.controllingWorkload(pod) ?? "",   // not a column; used by the delete confirm
                "age": Age.format(pod.metadata.creationTimestamp), "created": Age.absolute(pod.metadata.creationTimestamp),
            ],
            sortValues: [
                "ready": Double(PodStatusDerivation.readyCount(pod)),
                "restarts": Double(restarts),
                "cpu": req.cpuMillis,
                "mem": req.memBytes,
                "age": Age.seconds(pod.metadata.creationTimestamp),
            ])
    }

    static func namespace(_ ns: K8sNamespace) -> ResourceRow {
        let phase = ns.status?.phase ?? "Active"
        return ResourceRow(
            kind: .namespaces,
            namespace: "",
            name: ns.metadata.name,
            statusText: phase,
            statusKind: phase == "Active" ? .neutral : .terminating,
            cells: ["age": Age.format(ns.metadata.creationTimestamp), "created": Age.absolute(ns.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(ns.metadata.creationTimestamp)])
    }

    static func node(_ node: K8sNode, usage: NodeUsage?) -> ResourceRow {
        let ready = node.status?.conditions?.first { $0.type == "Ready" }?.status == "True"
        return ResourceRow(
            kind: .nodes,
            namespace: "",
            name: node.metadata.name,
            statusText: ready ? "Ready" : "NotReady",
            statusKind: ready ? .healthy : .error,
            cells: [
                "arch": node.status?.nodeInfo?.architecture ?? "—",
                "cpu": usage?.cpuText ?? "—",
                "cpupct": usage?.cpuPctText ?? "—",
                "mem": usage?.memText ?? "—",
                "mempct": usage?.memPctText ?? "—",
                "age": Age.format(node.metadata.creationTimestamp), "created": Age.absolute(node.metadata.creationTimestamp),
            ],
            sortValues: [
                "cpu": usage?.cpuMillis ?? 0,
                "cpupct": usage?.cpuPct ?? 0,
                "mem": usage?.memBytes ?? 0,
                "mempct": usage?.memPct ?? 0,
                "age": Age.seconds(node.metadata.creationTimestamp),
            ])
    }

    static func event(_ e: K8sEvent) -> ResourceRow {
        let type = e.type ?? "Normal"
        let objText = [e.involvedObject?.kind, e.involvedObject?.name]
            .compactMap { $0 }.joined(separator: "/")
        let last = e.lastTimestamp ?? e.firstTimestamp ?? e.metadata.creationTimestamp
        let message = (e.message ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return ResourceRow(
            kind: .events,
            namespace: e.metadata.namespace ?? "",
            name: e.reason ?? "—",   // the event itself, shown in the leading column (with Type icon)
            statusText: type,
            statusKind: type == "Warning" ? .warning : .neutral,
            cells: [
                "reason": e.reason ?? "—",
                "message": message.isEmpty ? "—" : message,
                "count": "\(e.count ?? 1)",
                "type": type,
                "object": objText.isEmpty ? "—" : objText,
                "source": e.source?.component ?? "—",
                "first": Age.timestamp(e.firstTimestamp),
                "age": Age.timestamp(last),
            ],
            sortValues: [
                "count": Double(e.count ?? 1),
                "age": Age.seconds(last),
            ],
            uid: e.metadata.name)   // events' name is the reason → use the real name as identity
    }

    static func deployment(_ dep: K8sDeployment) -> ResourceRow {
        let desired = dep.spec?.replicas ?? 0
        let ready = dep.status?.readyReplicas ?? 0
        let updated = dep.status?.updatedReplicas ?? 0
        let available = dep.status?.availableReplicas ?? 0
        var (text, kind) = replicaStatus(desired: desired, ready: ready, available: available)
        if let conds = dep.status?.conditions,
           let prog = conds.first(where: { $0.type == "Progressing" }),
           prog.status == "False" {
            kind = .error
            text = prog.reason ?? "Failed"
        }
        return ResourceRow(
            kind: .deployments,
            namespace: dep.metadata.namespace ?? "",
            name: dep.metadata.name,
            statusText: text, statusKind: kind,
            cells: [
                "ready": "\(ready)/\(desired)",
                "uptodate": "\(updated)",
                "available": "\(available)",
                "rollout": dep.spec?.strategy?.type ?? "RollingUpdate",   // not a column; drives the restart note
                "age": Age.format(dep.metadata.creationTimestamp), "created": Age.absolute(dep.metadata.creationTimestamp),
            ],
            sortValues: [
                "ready": Double(ready), "uptodate": Double(updated), "available": Double(available),
                "desired": Double(desired),   // current replica count, for the scale dialog
                "age": Age.seconds(dep.metadata.creationTimestamp),
            ])
    }

    static func statefulSet(_ ss: K8sStatefulSet) -> ResourceRow {
        let desired = ss.spec?.replicas ?? 0
        let ready = ss.status?.readyReplicas ?? 0
        let updated = ss.status?.updatedReplicas ?? 0
        let (text, kind) = replicaStatus(desired: desired, ready: ready, available: ready)
        return ResourceRow(
            kind: .statefulSets,
            namespace: ss.metadata.namespace ?? "",
            name: ss.metadata.name,
            statusText: text, statusKind: kind,
            cells: [
                "ready": "\(ready)/\(desired)",
                "uptodate": "\(updated)",
                "rollout": ss.spec?.updateStrategy?.type ?? "RollingUpdate",   // not a column; drives the restart note
                "age": Age.format(ss.metadata.creationTimestamp), "created": Age.absolute(ss.metadata.creationTimestamp),
            ],
            sortValues: [
                "ready": Double(ready), "uptodate": Double(updated),
                "desired": Double(desired),   // current replica count, for the scale dialog
                "age": Age.seconds(ss.metadata.creationTimestamp),
            ])
    }

    static func replicaSet(_ rs: K8sReplicaSet) -> ResourceRow {
        let desired = rs.spec?.replicas ?? 0
        let current = rs.status?.replicas ?? 0
        let ready = rs.status?.readyReplicas ?? 0
        let (text, kind) = replicaStatus(desired: desired, ready: ready, available: rs.status?.availableReplicas ?? ready)
        return ResourceRow(
            kind: .replicaSets,
            namespace: rs.metadata.namespace ?? "",
            name: rs.metadata.name,
            statusText: text, statusKind: kind,
            cells: [
                "desired": "\(desired)",
                "current": "\(current)",
                "ready": "\(ready)",
                "age": Age.format(rs.metadata.creationTimestamp), "created": Age.absolute(rs.metadata.creationTimestamp),
            ],
            sortValues: [
                "desired": Double(desired), "current": Double(current), "ready": Double(ready),
                "age": Age.seconds(rs.metadata.creationTimestamp),
            ])
    }

    static func daemonSet(_ ds: K8sDaemonSet) -> ResourceRow {
        let desired = ds.status?.desiredNumberScheduled ?? 0
        let current = ds.status?.currentNumberScheduled ?? 0
        let ready = ds.status?.numberReady ?? 0
        let updated = ds.status?.updatedNumberScheduled ?? 0
        let available = ds.status?.numberAvailable ?? ready
        let (text, kind) = replicaStatus(desired: desired, ready: ready, available: available)
        return ResourceRow(
            kind: .daemonSets,
            namespace: ds.metadata.namespace ?? "",
            name: ds.metadata.name,
            statusText: text, statusKind: kind,
            cells: [
                "desired": "\(desired)",
                "current": "\(current)",
                "ready": "\(ready)",
                "uptodate": "\(updated)",
                "available": "\(available)",
                "rollout": ds.spec?.updateStrategy?.type ?? "RollingUpdate",   // not a column; drives the restart note
                "age": Age.format(ds.metadata.creationTimestamp), "created": Age.absolute(ds.metadata.creationTimestamp),
            ],
            sortValues: [
                "desired": Double(desired), "current": Double(current), "ready": Double(ready),
                "uptodate": Double(updated), "available": Double(available),
                "age": Age.seconds(ds.metadata.creationTimestamp),
            ])
    }

    static func configMap(_ cm: K8sConfigMap) -> ResourceRow {
        let keys = (cm.data?.count ?? 0) + (cm.binaryData?.count ?? 0)
        return ResourceRow(
            kind: .configMaps, namespace: cm.metadata.namespace ?? "", name: cm.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["keys": "\(keys)", "age": Age.format(cm.metadata.creationTimestamp), "created": Age.absolute(cm.metadata.creationTimestamp)],
            sortValues: ["keys": Double(keys), "age": Age.seconds(cm.metadata.creationTimestamp)])
    }

    static func secret(_ s: K8sSecret) -> ResourceRow {
        let keys = s.data?.count ?? 0
        return ResourceRow(
            kind: .secrets, namespace: s.metadata.namespace ?? "", name: s.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["type": s.type ?? "Opaque", "keys": "\(keys)", "age": Age.format(s.metadata.creationTimestamp), "created": Age.absolute(s.metadata.creationTimestamp)],
            sortValues: ["keys": Double(keys), "age": Age.seconds(s.metadata.creationTimestamp)])
    }

    static func service(_ svc: K8sService) -> ResourceRow {
        let ip = svc.spec?.clusterIP ?? "—"
        let ports = (svc.spec?.ports ?? []).map {
            ($0.port.map(String.init) ?? "?") + ($0.proto.map { "/\($0)" } ?? "")
        }.joined(separator: ", ")
        return ResourceRow(
            kind: .services, namespace: svc.metadata.namespace ?? "", name: svc.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["type": svc.spec?.type ?? "ClusterIP", "clusterIP": ip,
                    "ports": ports.isEmpty ? "—" : ports, "age": Age.format(svc.metadata.creationTimestamp), "created": Age.absolute(svc.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(svc.metadata.creationTimestamp)])
    }

    static func ingress(_ ing: K8sIngress) -> ResourceRow {
        let hosts = (ing.spec?.rules ?? []).compactMap { $0.host }.joined(separator: ", ")
        let entry = ing.status?.loadBalancer?.ingress?.first
        let address = entry?.ip ?? entry?.hostname ?? "—"
        return ResourceRow(
            kind: .ingresses, namespace: ing.metadata.namespace ?? "", name: ing.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["hosts": hosts.isEmpty ? "—" : hosts, "address": address,
                    "age": Age.format(ing.metadata.creationTimestamp), "created": Age.absolute(ing.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(ing.metadata.creationTimestamp)])
    }

    static func pvc(_ p: K8sPVC) -> ResourceRow {
        let phase = p.status?.phase ?? "Unknown"
        let kind: StatusKind
        switch phase {
        case "Bound": kind = .healthy
        case "Pending": kind = .pending
        case "Lost": kind = .error
        default: kind = .unknown
        }
        let capacity = p.status?.capacity?.storage ?? p.spec?.resources?.requests?.storage ?? "—"
        return ResourceRow(
            kind: .persistentVolumeClaims, namespace: p.metadata.namespace ?? "", name: p.metadata.name,
            statusText: phase, statusKind: kind,
            cells: ["capacity": capacity, "storageClass": p.spec?.storageClassName ?? "—",
                    "age": Age.format(p.metadata.creationTimestamp), "created": Age.absolute(p.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(p.metadata.creationTimestamp)])
    }

    static func networkPolicy(_ np: K8sNetworkPolicy) -> ResourceRow {
        let sel = np.spec?.podSelector?.matchLabels ?? [:]
        let selText = sel.isEmpty ? "all pods" : sel.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        let types = (np.spec?.policyTypes ?? []).joined(separator: ", ")
        return ResourceRow(
            kind: .networkPolicies, namespace: np.metadata.namespace ?? "", name: np.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["podSelector": selText, "policyTypes": types.isEmpty ? "—" : types,
                    "age": Age.format(np.metadata.creationTimestamp), "created": Age.absolute(np.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(np.metadata.creationTimestamp)])
    }

    static func endpoints(_ ep: K8sEndpoints) -> ResourceRow {
        var pairs: [String] = []
        var count = 0
        for subset in ep.subsets ?? [] {
            let ips = (subset.addresses ?? []).compactMap { $0.ip }
            count += ips.count
            let ports = (subset.ports ?? []).compactMap { $0.port.map(String.init) }
            for ip in ips {
                if ports.isEmpty { pairs.append(ip) }
                else { ports.forEach { pairs.append("\(ip):\($0)") } }
            }
        }
        let summary = pairs.isEmpty ? "<none>"
            : pairs.prefix(6).joined(separator: ", ") + (pairs.count > 6 ? " +\(pairs.count - 6)" : "")
        return ResourceRow(
            kind: .endpoints, namespace: ep.metadata.namespace ?? "", name: ep.metadata.name,
            statusText: "", statusKind: count == 0 ? .warning : .neutral,   // no endpoints = a red flag
            cells: ["endpoints": summary, "count": "\(count)", "age": Age.format(ep.metadata.creationTimestamp), "created": Age.absolute(ep.metadata.creationTimestamp)],
            sortValues: ["count": Double(count), "age": Age.seconds(ep.metadata.creationTimestamp)])
    }

    static func pv(_ pv: K8sPV) -> ResourceRow {
        let phase = pv.status?.phase ?? "Unknown"
        let kind: StatusKind
        switch phase {
        case "Bound", "Available": kind = .healthy
        case "Released": kind = .warning
        case "Failed": kind = .error
        case "Pending": kind = .pending
        default: kind = .unknown
        }
        let ref = pv.spec?.claimRef
        let claim = ref.flatMap { r -> String? in
            guard let n = r.name else { return nil }
            return r.namespace.map { "\($0)/\(n)" } ?? n
        } ?? "—"
        return ResourceRow(
            kind: .persistentVolumes, namespace: "", name: pv.metadata.name,
            statusText: phase, statusKind: kind,
            cells: ["capacity": pv.spec?.capacity?.storage ?? "—",
                    "accessModes": (pv.spec?.accessModes ?? []).map(shortAccessMode).joined(separator: ","),
                    "reclaim": pv.spec?.persistentVolumeReclaimPolicy ?? "—",
                    "storageClass": pv.spec?.storageClassName ?? "—",
                    "claim": claim, "age": Age.format(pv.metadata.creationTimestamp), "created": Age.absolute(pv.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(pv.metadata.creationTimestamp)])
    }

    private static func shortAccessMode(_ m: String) -> String {
        switch m {
        case "ReadWriteOnce": return "RWO"
        case "ReadOnlyMany": return "ROX"
        case "ReadWriteMany": return "RWX"
        case "ReadWriteOncePod": return "RWOP"
        default: return m
        }
    }

    static func storageClass(_ sc: K8sStorageClass) -> ResourceRow {
        let isDefault = sc.metadata.annotations?["storageclass.kubernetes.io/is-default-class"] == "true"
        return ResourceRow(
            kind: .storageClasses, namespace: "", name: sc.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["provisioner": sc.provisioner ?? "—",
                    "reclaim": sc.reclaimPolicy ?? "Delete",
                    "binding": sc.volumeBindingMode ?? "Immediate",
                    "default": isDefault ? "✓" : "",
                    "age": Age.format(sc.metadata.creationTimestamp), "created": Age.absolute(sc.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(sc.metadata.creationTimestamp)])
    }

    static func pdb(_ pdb: K8sPDB) -> ResourceRow {
        let current = pdb.status?.currentHealthy ?? 0
        let desired = pdb.status?.desiredHealthy ?? 0
        let allowed = pdb.status?.disruptionsAllowed ?? 0
        let ok = current >= desired
        return ResourceRow(
            kind: .podDisruptionBudgets, namespace: pdb.metadata.namespace ?? "", name: pdb.metadata.name,
            statusText: ok ? "Healthy" : "Degraded", statusKind: ok ? .healthy : .warning,
            cells: ["minAvailable": pdb.spec?.minAvailable?.text ?? "—",
                    "maxUnavailable": pdb.spec?.maxUnavailable?.text ?? "—",
                    "allowed": "\(allowed)", "age": Age.format(pdb.metadata.creationTimestamp), "created": Age.absolute(pdb.metadata.creationTimestamp)],
            sortValues: ["allowed": Double(allowed), "age": Age.seconds(pdb.metadata.creationTimestamp)])
    }

    static func job(_ j: K8sJob) -> ResourceRow {
        let succeeded = j.status?.succeeded ?? 0
        let completions = j.spec?.completions ?? 1
        let active = j.status?.active ?? 0
        let failed = j.status?.failed ?? 0
        var kind: StatusKind = .pending
        var text = "Running"
        let conds = j.status?.conditions ?? []
        if conds.contains(where: { $0.type == "Complete" && $0.status == "True" }) {
            kind = .healthy; text = "Complete"
        } else if conds.contains(where: { $0.type == "Failed" && $0.status == "True" }) {
            kind = .error; text = "Failed"
        } else if active > 0 {
            kind = .pending; text = "Running"
        } else if failed > 0 {
            kind = .warning; text = "Failed:\(failed)"
        }
        let duration = jobDuration(j.status?.startTime, j.status?.completionTime)
        return ResourceRow(
            kind: .jobs, namespace: j.metadata.namespace ?? "", name: j.metadata.name,
            statusText: text, statusKind: kind,
            cells: ["completions": "\(succeeded)/\(completions)", "duration": duration,
                    "age": Age.format(j.metadata.creationTimestamp), "created": Age.absolute(j.metadata.creationTimestamp)],
            sortValues: ["completions": Double(succeeded), "age": Age.seconds(j.metadata.creationTimestamp)])
    }

    static func cronJob(_ c: K8sCronJob) -> ResourceRow {
        let suspended = c.spec?.suspend ?? false
        let lastRun = c.status?.lastScheduleTime.map { Age.format($0) } ?? "—"
        return ResourceRow(
            kind: .cronJobs, namespace: c.metadata.namespace ?? "", name: c.metadata.name,
            statusText: "", statusKind: suspended ? .warning : .neutral,
            cells: ["schedule": c.spec?.schedule ?? "—", "suspend": suspended ? "Yes" : "No",
                    "lastRun": lastRun, "age": Age.format(c.metadata.creationTimestamp), "created": Age.absolute(c.metadata.creationTimestamp)],
            sortValues: ["age": Age.seconds(c.metadata.creationTimestamp)])
    }

    static func serviceAccount(_ sa: K8sServiceAccount) -> ResourceRow {
        let n = sa.secrets?.count ?? 0
        return ResourceRow(
            kind: .serviceAccounts, namespace: sa.metadata.namespace ?? "", name: sa.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["secrets": "\(n)", "age": Age.format(sa.metadata.creationTimestamp), "created": Age.absolute(sa.metadata.creationTimestamp)],
            sortValues: ["secrets": Double(n), "age": Age.seconds(sa.metadata.creationTimestamp)])
    }

    static func hpa(_ h: K8sHPA) -> ResourceRow {
        let current = h.status?.currentReplicas ?? 0
        let desired = h.status?.desiredReplicas ?? current
        return ResourceRow(
            kind: .horizontalPodAutoscalers, namespace: h.metadata.namespace ?? "", name: h.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["min": "\(h.spec?.minReplicas ?? 0)", "max": "\(h.spec?.maxReplicas ?? 0)",
                    "replicas": "\(current)/\(desired)", "age": Age.format(h.metadata.creationTimestamp), "created": Age.absolute(h.metadata.creationTimestamp)],
            sortValues: ["replicas": Double(current), "age": Age.seconds(h.metadata.creationTimestamp)])
    }

    private static func jobDuration(_ start: String?, _ end: String?) -> String {
        guard let start, let startDate = Age.parse(start) else { return "—" }
        let endDate = end.flatMap(Age.parse) ?? Date()
        return Age.humanize(max(0, endDate.timeIntervalSince(startDate)))
    }

    /// Shared readiness verdict for the controller kinds.
    static func replicaStatus(desired: Int, ready: Int, available: Int) -> (String, StatusKind) {
        if desired == 0 { return ("Scaled to 0", .completed) }
        if ready >= desired && available >= desired { return ("Available", .healthy) }
        if ready == 0 { return ("Unavailable", .error) }
        return ("Progressing", .warning)
    }
}

// MARK: - Pod status derivation

/// Replicates kubectl's `printPod` STATUS-column logic closely enough for a viewer.
enum PodStatusDerivation {
    static func derive(_ pod: K8sPod) -> (String, StatusKind) {
        let status = pod.status
        var reason = status?.phase ?? "Unknown"
        if let r = status?.reason, !r.isEmpty { reason = r }

        var initializing = false
        let initStatuses = status?.initContainerStatuses ?? []
        for (i, ics) in initStatuses.enumerated() {
            if let term = ics.state?.terminated {
                if (term.exitCode ?? 0) == 0 && (term.signal ?? 0) == 0 { continue }
                if let sig = term.signal, sig != 0 {
                    reason = "Init:Signal:\(sig)"
                } else if let r = term.reason, !r.isEmpty {
                    reason = "Init:\(r)"
                } else if let code = term.exitCode {
                    reason = "Init:ExitCode:\(code)"
                }
                initializing = true
            } else if let wait = ics.state?.waiting,
                      let r = wait.reason, !r.isEmpty, r != "PodInitializing" {
                reason = "Init:\(r)"
                initializing = true
            } else {
                reason = "Init:\(i)/\(initStatuses.count)"
                initializing = true
            }
            break
        }

        if !initializing {
            let cstatuses = status?.containerStatuses ?? []
            for cs in cstatuses.reversed() {
                if let wait = cs.state?.waiting, let r = wait.reason, !r.isEmpty {
                    reason = r
                } else if let term = cs.state?.terminated {
                    if let r = term.reason, !r.isEmpty {
                        reason = r
                    } else if let sig = term.signal, sig != 0 {
                        reason = "Signal:\(sig)"
                    } else if let code = term.exitCode {
                        reason = "ExitCode:\(code)"
                    }
                }
            }
        }

        if pod.metadata.deletionTimestamp != nil {
            reason = (status?.reason == "NodeLost") ? "Unknown" : "Terminating"
        }

        return (reason, kind(for: reason, allReady: isAllReady(pod)))
    }

    static func kind(for reason: String, allReady: Bool) -> StatusKind {
        if reason == "Running" { return allReady ? .healthy : .warning }
        if reason == "Completed" || reason == "Succeeded" { return .completed }
        if reason == "Terminating" { return .terminating }

        let r = reason.lowercased()
        let errorMarkers = ["err", "backoff", "crashloop", "failed", "evicted",
                            "oomkilled", "exitcode", "signal", "invalid", "cannot",
                            "unknown", "deadlineexceeded"]
        if errorMarkers.contains(where: { r.contains($0) }) { return .error }

        if reason == "Pending" || reason == "ContainerCreating"
            || reason == "PodInitializing" || r.hasPrefix("init:") {
            return .pending
        }
        return .warning
    }

    static func isAllReady(_ pod: K8sPod) -> Bool {
        let cs = pod.status?.containerStatuses ?? []
        guard !cs.isEmpty else { return false }
        return cs.allSatisfy { $0.ready ?? false }
    }

    static func readyCount(_ pod: K8sPod) -> Int {
        (pod.status?.containerStatuses ?? []).filter { $0.ready ?? false }.count
    }

    static func readyString(_ pod: K8sPod) -> String {
        let cs = pod.status?.containerStatuses ?? []
        let total = cs.isEmpty ? (pod.spec?.containers?.count ?? 0) : cs.count
        let ready = cs.filter { $0.ready ?? false }.count
        return "\(ready)/\(total)"
    }

    static func restartCount(_ pod: K8sPod) -> Int {
        let cs = pod.status?.containerStatuses ?? []
        return cs.reduce(0) { $0 + ($1.restartCount ?? 0) }
    }

    /// Plain-language "why is this pod (un)healthy" report plus restart/OOM
    /// forensics. Formatted as `Key: value` / header lines so DescribeFormatter
    /// colors it. Reads only status reasons/messages — never env vars or secrets.
    /// The workload that owns this pod, as "Kind/name" (for a clickable owner link).
    /// A pod's direct owner is a ReplicaSet, so resolve it to the parent Deployment
    /// by stripping the pod-template-hash suffix (RS name = <deployment>-<hash>).
    static func controllingWorkload(_ pod: K8sPod) -> String? {
        let owners = pod.metadata.ownerReferences ?? []
        guard let owner = owners.first(where: { $0.controller == true }) ?? owners.first,
              let kind = owner.kind, let name = owner.name else { return nil }
        if kind == "ReplicaSet", let hash = pod.metadata.labels?["pod-template-hash"],
           name.hasSuffix("-\(hash)") {
            return "Deployment/\(String(name.dropLast(hash.count + 1)))"
        }
        return "\(kind)/\(name)"
    }

    static func healthReport(_ pod: K8sPod) -> String {
        let (reason, kind) = derive(pod)
        let status = pod.status
        var notes: [String] = []

        if let bad = (status?.conditions ?? []).first(where: { $0.status == "False" && ($0.message?.isEmpty == false) }),
           (status?.containerStatuses ?? []).isEmpty || reason == "Pending" {
            notes.append("Not scheduled/ready: \(bad.message ?? bad.reason ?? "—")")
        }
        for cs in status?.initContainerStatuses ?? [] {
            if let w = cs.state?.waiting, let r = w.reason, !r.isEmpty, r != "PodInitializing" {
                notes.append("Init container “\(cs.name)”: \(explain(r)).")
            } else if let t = cs.state?.terminated, (t.exitCode ?? 0) != 0 {
                notes.append("Init container “\(cs.name)” failed: \(terminationCause(t)).")
            }
        }
        for cs in status?.containerStatuses ?? [] {
            if let w = cs.state?.waiting, let r = w.reason, !r.isEmpty {
                notes.append("Container “\(cs.name)”: \(explain(r)).")
            } else if let t = cs.state?.terminated, t.reason != "Completed",
                      (t.exitCode ?? 0) != 0 || (t.signal ?? 0) != 0 {
                notes.append("Container “\(cs.name)”: \(terminationCause(t)).")
            }
            if let lt = cs.lastState?.terminated, (lt.exitCode ?? 0) != 0 || lt.reason == "OOMKilled" {
                let ago = Age.format(lt.finishedAt)
                let when = ago == "—" ? "" : ", \(ago) ago"
                notes.append("Container “\(cs.name)” previously \(terminationCause(lt))\(when) — restarted \(cs.restartCount ?? 0)×.")
            }
        }
        if notes.isEmpty {
            notes.append(kind == .healthy
                ? "This pod looks healthy — all containers are running and ready."
                : "Current status is “\(reason)”.")
        }

        func row(_ k: String, _ v: String) -> String {
            "\(k):" + String(repeating: " ", count: max(1, 14 - k.count)) + v
        }
        var lines = [row("Namespace", pod.metadata.namespace ?? "—")]
        if let workload = controllingWorkload(pod) { lines.append(row("Controlled By", workload)) }
        lines += [row("Status", reason), row("Ready", readyString(pod)), row("Restarts", "\(restartCount(pod))"),
                  "", "Diagnosis:", notes.joined(separator: "\n")]
        var out = lines.joined(separator: "\n")
        let containers = status?.containerStatuses ?? []
        if !containers.isEmpty {
            out += "\n\nContainers:\n"
            out += containers.map { "\($0.name):  \(stateSummary($0))" }.joined(separator: "\n")
        }
        return out
    }

    /// Per-container inspector (image, state, ready, ports, requests/limits),
    /// joining spec containers with their status by name. Formatted as
    /// `name:` header + `Key: value` lines for DescribeFormatter coloring.
    static func containersReport(_ pod: K8sPod) -> String {
        let running = byName(pod.status?.containerStatuses)
        let inits = byName(pod.status?.initContainerStatuses)
        var blocks: [String] = []
        for c in pod.spec?.initContainers ?? [] { blocks.append(containerBlock(c, status: inits[c.name], suffix: "  (init)")) }
        for c in pod.spec?.containers ?? [] { blocks.append(containerBlock(c, status: running[c.name], suffix: "")) }
        return blocks.isEmpty ? "No containers." : blocks.joined(separator: "\n\n")
    }

    /// The pod's "wiring": volumes (with clickable ConfigMap/Secret/PVC sources) +
    /// where each is mounted, environment (secret *values* hidden — only refs), and
    /// probes. Formatted as `Key: value` lines for DescribeFormatter coloring/links.
    static func mountsReport(_ pod: K8sPod) -> String {
        let containers = (pod.spec?.initContainers ?? []) + (pod.spec?.containers ?? [])
        // Namespace first, so DescribeFormatter can resolve the CM/Secret/PVC links.
        var out = "Namespace:  \(pod.metadata.namespace ?? "—")\n"

        let volumes = pod.spec?.volumes ?? []
        if !volumes.isEmpty {
            out += "\nVolumes:\n"
            for v in volumes {
                out += "  \(v.name)  (\(volumeType(v)))\n"
                if let src = volumeSourceRow(v) { out += "    \(src)\n" }
                for m in mountsOf(v.name, in: containers) { out += "    \(m)\n" }
            }
        }

        let envBlocks = containers.compactMap(envBlock)
        if !envBlocks.isEmpty { out += "\nEnvironment:\n" + envBlocks.joined(separator: "\n") + "\n" }

        let probeBlocks = containers.compactMap(probeBlock)
        if !probeBlocks.isEmpty { out += "\nProbes:\n" + probeBlocks.joined(separator: "\n") + "\n" }

        if volumes.isEmpty && envBlocks.isEmpty && probeBlocks.isEmpty {
            out += "\nNo volumes, environment, or probes."
        }
        return out
    }

    private static func volumeType(_ v: PodVolume) -> String {
        if v.configMap != nil { return "ConfigMap" }
        if v.secret != nil { return "Secret" }
        if v.persistentVolumeClaim != nil { return "PVC" }
        if v.hostPath != nil { return "hostPath" }
        if v.emptyDir != nil { return "emptyDir" }
        if v.projected != nil { return "projected" }
        if v.downwardAPI != nil { return "downwardAPI" }
        return "—"
    }

    /// Source line whose key DescribeFormatter turns into a clickable cross-ref.
    private static func volumeSourceRow(_ v: PodVolume) -> String? {
        if let cm = v.configMap?.name { return "ConfigMap:  \(cm)" }
        if let s = v.secret?.secretName { return "Secret:  \(s)" }
        if let pvc = v.persistentVolumeClaim?.claimName { return "PVC:  \(pvc)" }
        if let hp = v.hostPath?.path { return "Path:  \(hp)" }
        return nil
    }

    private static func mountsOf(_ volName: String, in containers: [NamedContainer]) -> [String] {
        containers.flatMap { c in
            (c.volumeMounts ?? []).filter { $0.name == volName }.map { m in
                var line = "→ \(c.name)  \(m.mountPath ?? "?")"
                if m.readOnly == true { line += "  (ro)" }
                if let sp = m.subPath, !sp.isEmpty { line += "  subPath=\(sp)" }
                return line
            }
        }
    }

    private static func envBlock(_ c: NamedContainer) -> String? {
        var lines: [String] = []
        for e in c.env ?? [] {
            if let val = e.value {
                lines.append("    \(e.name)=\(val)")
            } else if let cm = e.valueFrom?.configMapKeyRef {
                lines.append("    \(e.name) ←  configMap \(cm.name ?? "?")/\(cm.key ?? "?")")
            } else if let s = e.valueFrom?.secretKeyRef {
                lines.append("    \(e.name) ←  secret \(s.name ?? "?")/\(s.key ?? "?")  (hidden)")
            } else if let f = e.valueFrom?.fieldRef {
                lines.append("    \(e.name) ←  field \(f.fieldPath ?? "?")")
            } else if let r = e.valueFrom?.resourceFieldRef {
                lines.append("    \(e.name) ←  resource \(r.resource ?? "?")")
            } else {
                lines.append("    \(e.name)")
            }
        }
        for f in c.envFrom ?? [] {
            let p = f.prefix.map { "\($0) " } ?? ""
            if let cm = f.configMapRef?.name { lines.append("    envFrom \(p)configMap \(cm)") }
            if let s = f.secretRef?.name { lines.append("    envFrom \(p)secret \(s)") }
        }
        guard !lines.isEmpty else { return nil }
        return "  \(c.name):\n" + lines.joined(separator: "\n")
    }

    private static func probeBlock(_ c: NamedContainer) -> String? {
        var lines: [String] = []
        func add(_ label: String, _ p: Probe?) {
            guard let p, let action = probeAction(p) else { return }
            var line = "    \(label):  \(action)"
            var timing: [String] = []
            if let d = p.initialDelaySeconds, d > 0 { timing.append("delay \(d)s") }
            if let pd = p.periodSeconds { timing.append("period \(pd)s") }
            if !timing.isEmpty { line += "  (\(timing.joined(separator: " · ")))" }
            lines.append(line)
        }
        add("Liveness", c.livenessProbe)
        add("Readiness", c.readinessProbe)
        add("Startup", c.startupProbe)
        guard !lines.isEmpty else { return nil }
        return "  \(c.name):\n" + lines.joined(separator: "\n")
    }

    private static func probeAction(_ p: Probe) -> String? {
        if let h = p.httpGet {
            return "\((h.scheme ?? "HTTP").lowercased()) \(h.path ?? "/") : \(h.port?.text ?? "?")"
        }
        if let t = p.tcpSocket { return "tcp \(t.port?.text ?? "?")" }
        if let e = p.exec { return "exec \(e.command?.joined(separator: " ") ?? "")" }
        return nil
    }

    private static func byName(_ list: [ContainerStatus]?) -> [String: ContainerStatus] {
        Dictionary((list ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func containerBlock(_ spec: NamedContainer, status: ContainerStatus?, suffix: String) -> String {
        var lines = ["\(spec.name)\(suffix):"]
        lines.append("  Image:     \(status?.image ?? spec.image ?? "—")")
        lines.append("  State:     \(status.map(stateSummary) ?? "not started")")
        if let ready = status?.ready { lines.append("  Ready:     \(ready ? "yes" : "no")") }
        if let ports = spec.ports, !ports.isEmpty {
            lines.append("  Ports:     " + ports.map { "\($0.containerPort ?? 0)/\($0.proto ?? "TCP")" }.joined(separator: ", "))
        }
        if let r = resourceLine(spec.resources?.requests) { lines.append("  Requests:  \(r)") }
        if let l = resourceLine(spec.resources?.limits) { lines.append("  Limits:    \(l)") }
        return lines.joined(separator: "\n")
    }

    private static func resourceLine(_ r: ResourceList?) -> String? {
        guard let r else { return nil }
        var parts: [String] = []
        if let c = r.cpu { parts.append("\(c) CPU") }
        if let m = r.memory { parts.append(m) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Map a waiting/terminated reason to a developer-readable sentence fragment.
    private static func explain(_ reason: String) -> String {
        switch reason {
        case "CrashLoopBackOff":          return "keeps crashing and restarting"
        case "ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull":
                                          return "image can’t be pulled — check the image name/tag and registry credentials"
        case "InvalidImageName":          return "the image name is invalid"
        case "CreateContainerConfigError": return "config error — a referenced ConfigMap/Secret or key is missing"
        case "CreateContainerError", "RunContainerError":
                                          return "the container runtime failed to start it"
        case "OOMKilled":                 return "ran out of memory (OOMKilled)"
        case "Error":                     return "exited with an error"
        case "ContainerCreating":         return "is still being created"
        case "PodInitializing":           return "is waiting for init containers"
        default:                          return reason
        }
    }

    /// Human description of a terminated state (OOM / signal / exit code).
    private static func terminationCause(_ t: TerminatedState) -> String {
        if t.reason == "OOMKilled" { return "ran out of memory (OOMKilled, exit \(t.exitCode ?? 137))" }
        if let r = t.reason, !r.isEmpty, r != "Error" { return "\(r) (exit \(t.exitCode ?? 0))" }
        if let sig = t.signal, sig != 0 { return "killed by signal \(sig)" }
        if let code = t.exitCode { return code == 0 ? "exited cleanly" : "exited with code \(code)" }
        return "terminated"
    }

    /// One-line current state of a container, with restart count and last failure.
    private static func stateSummary(_ cs: ContainerStatus) -> String {
        var s: String
        if let r = cs.state?.running {
            let up = Age.format(r.startedAt)
            s = up == "—" ? "Running" : "Running (up \(up))"
        } else if let w = cs.state?.waiting, let r = w.reason, !r.isEmpty {
            s = "Waiting — \(r)"
        } else if let t = cs.state?.terminated {
            s = "Terminated — \(terminationCause(t))"
        } else {
            s = "—"
        }
        if let n = cs.restartCount, n > 0 { s += " · \(n) restart\(n == 1 ? "" : "s")" }
        if let lt = cs.lastState?.terminated, (lt.exitCode ?? 0) != 0 || lt.reason == "OOMKilled" {
            let ago = Age.format(lt.finishedAt)
            s += " · last: \(terminationCause(lt))\(ago == "—" ? "" : " \(ago) ago")"
        }
        return s
    }

    static func requestedResources(_ pod: K8sPod) -> (cpu: String, memory: String, cpuMillis: Double, memBytes: Double) {
        var cpuMillis = 0.0, memBytes = 0.0
        var hasCPU = false, hasMem = false
        for container in pod.spec?.containers ?? [] {
            if let cpu = container.resources?.requests?.cpu,
               let m = Quantity.cpuMillicores(cpu) {
                cpuMillis += m; hasCPU = true
            }
            if let mem = container.resources?.requests?.memory,
               let b = Quantity.memoryBytes(mem) {
                memBytes += b; hasMem = true
            }
        }
        return (hasCPU ? Quantity.formatCPU(cpuMillis) : "—",
                hasMem ? Quantity.formatMemory(memBytes) : "—",
                cpuMillis, memBytes)
    }
}

// MARK: - Namespace resource inventory

/// One resource entity in a namespace, with the fields common to every kind.
struct NamespaceResource: Sendable {
    let kind: ResourceKind?     // resolved for navigation (nil = kind we don't list elsewhere)
    let kindLabel: String       // API kind for display, e.g. "Pod", "ReplicaSet"
    let name: String
    let age: String
    let ageSeconds: Double
}

/// The kinds queried for a namespace's full entity list, and the map from the
/// JSON `kind` back to our ResourceKind (for double-click navigation).
enum NamespaceInventory {
    static let queryKinds: [ResourceKind] = [
        .pods, .deployments, .statefulSets, .daemonSets, .replicaSets, .services,
        .ingresses, .configMaps, .secrets, .serviceAccounts, .persistentVolumeClaims,
        .jobs, .cronJobs, .horizontalPodAutoscalers,
    ]

    static var query: String { queryKinds.map { $0.kubectlResource }.joined(separator: ",") }

    static let kindByApiKind: [String: ResourceKind] = [
        "Pod": .pods, "Deployment": .deployments, "StatefulSet": .statefulSets,
        "DaemonSet": .daemonSets, "ReplicaSet": .replicaSets, "Service": .services,
        "Ingress": .ingresses, "ConfigMap": .configMaps, "Secret": .secrets,
        "ServiceAccount": .serviceAccounts, "PersistentVolumeClaim": .persistentVolumeClaims,
        "Job": .jobs, "CronJob": .cronJobs, "HorizontalPodAutoscaler": .horizontalPodAutoscalers,
        "NetworkPolicy": .networkPolicies, "Endpoints": .endpoints, "PersistentVolume": .persistentVolumes,
        "StorageClass": .storageClasses, "PodDisruptionBudget": .podDisruptionBudgets,
    ]
}

// MARK: - Node usage (`kubectl top nodes`)

/// Per-node usage parsed from `kubectl top nodes --no-headers`
/// (NAME  CPU(cores)  CPU%  MEMORY(bytes)  MEMORY%).
struct NodeUsage: Sendable {
    var cpuText: String, cpuPctText: String, memText: String, memPctText: String
    var cpuMillis: Double, cpuPct: Double, memBytes: Double, memPct: Double

    static func parse(_ text: String) -> [String: NodeUsage] {
        var result: [String: NodeUsage] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 5 else { continue }
            func pct(_ s: String) -> Double { Double(s.replacingOccurrences(of: "%", with: "")) ?? 0 }
            result[t[0]] = NodeUsage(
                cpuText: t[1], cpuPctText: t[2], memText: t[3], memPctText: t[4],
                cpuMillis: Quantity.cpuMillicores(t[1]) ?? 0, cpuPct: pct(t[2]),
                memBytes: Quantity.memoryBytes(t[3]) ?? 0, memPct: pct(t[4]))
        }
        return result
    }
}

