import Foundation

// MARK: - Age formatting (kubectl-like compact durations)

enum Age {
    /// The age column's text, hover tooltip and sort key from a single parse —
    /// one parse of `creationTimestamp` per row instead of three.
    struct Stamp {
        let text: String       // "5m12s" / "3d4h"; "—" if unparseable
        let absolute: String   // "Jul 3, 2026  07:13:28" (local); "—" if unparseable
        let seconds: Double    // for sorting; 0 if unparseable
    }

    // FormatStyles are Sendable value types, so shared instances are fine under strict
    // concurrency (ISO8601DateFormatter / DateFormatter aren't, and cost ~100µs to make).
    private static let iso = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)   // MicroTime (events)
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let absoluteStyle = Date.VerbatimFormatStyle(
        format: "\(month: .abbreviated) \(day: .defaultDigits), \(year: .defaultDigits)  \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        locale: posix, timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent)
    private static let timeStyle = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        locale: posix, timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent)
    private static let dayTimeStyle = Date.VerbatimFormatStyle(
        format: "\(month: .abbreviated) \(day: .defaultDigits)  \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        locale: posix, timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent)

    /// RFC 3339 as the API server writes it; the fractional form is tried second
    /// because only MicroTime fields (`eventTime`, `lastObservedTime`) carry it.
    static func parse(_ s: String) -> Date? {
        (try? iso.parse(s)) ?? (try? isoFractional.parse(s))
    }

    static func stamp(_ iso: String?, now: Date = Date()) -> Stamp {
        guard let iso, let date = parse(iso) else { return Stamp(text: "—", absolute: "—", seconds: 0) }
        let secs = seconds(since: date, now: now)
        return Stamp(text: humanize(secs), absolute: absoluteStyle.format(date), seconds: secs)
    }

    static func format(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = parse(iso) else { return "—" }
        return humanize(seconds(since: date, now: now))
    }

    static func seconds(since date: Date, now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(date))
    }

    /// Absolute local timestamp: "HH:mm:ss" if it's today, "MMM d  HH:mm:ss"
    /// otherwise (so older events carry the day).
    static func timestamp(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? timeStyle.format(date) : dayTimeStyle.format(date)
    }

    /// kubectl's `duration.HumanDuration`: two units only while the coarse one is
    /// small (`4m3s`, `2h5m`, `3d4h`, `2y5d`), one unit after that.
    static func humanize(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 120 { return "\(s)s" }
        let m = s / 60
        if m < 10 { return s % 60 == 0 ? "\(m)m" : "\(m)m\(s % 60)s" }
        if m < 180 { return "\(m)m" }
        let h = m / 60
        if h < 8 { return m % 60 == 0 ? "\(h)h" : "\(h)h\(m % 60)m" }
        if h < 48 { return "\(h)h" }
        let d = h / 24
        if h < 24 * 8 { return h % 24 == 0 ? "\(d)d" : "\(d)d\(h % 24)h" }
        if h < 24 * 365 * 2 { return "\(d)d" }
        let y = d / 365
        if h < 24 * 365 * 8 { return d % 365 == 0 ? "\(y)y" : "\(y)y\(d % 365)d" }
        return "\(y)y"
    }
}

// MARK: - Kubernetes resource quantities

/// Parser for Kubernetes quantity strings (`resource.Quantity`): binary suffixes
/// Ki…Ei, decimal n/u/m/k/M/G/T/P/E, and the exponent form (`1e3`). The API
/// canonicalizes values, so `memory: 1.5` comes back as `1500m` and a tiny CPU
/// request as `100n` — both must parse, or the column shows "—" and sorts as 0.
enum Quantity {
    private static let suffixes: [(String, Double)] = [
        ("Ki", 1024), ("Mi", 1048576), ("Gi", 1073741824), ("Ti", 1099511627776),
        ("Pi", 1125899906842624), ("Ei", 1152921504606846976),
        ("n", 1e-9), ("u", 1e-6), ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9),
        ("T", 1e12), ("P", 1e15), ("E", 1e18),
    ]

    /// The quantity as a plain number (cores for CPU, bytes for memory).
    static func value(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        for (suffix, mult) in suffixes where s.hasSuffix(suffix) {
            // "1e3" ends in a digit, so the exponent form never reaches here.
            return Double(s.dropLast(suffix.count)).map { $0 * mult }
        }
        return Double(s)   // plain number or exponent form ("1e3", "12E6")
    }

    static func cpuMillicores(_ s: String) -> Double? { value(s).map { $0 * 1000 } }
    static func memoryBytes(_ s: String) -> Double? { value(s) }

    static func formatCPU(_ millicores: Double) -> String {
        guard millicores > 0 else { return "—" }
        if millicores < 1 { return String(format: "%.2fm", millicores) }
        if millicores < 1000 { return "\(Int(millicores.rounded()))m" }
        return trim(millicores / 1000)
    }

    static func formatMemory(_ bytes: Double) -> String {
        guard bytes > 0 else { return "—" }
        if bytes < 1024 { return "\(Int(bytes.rounded()))" }
        let mi = bytes / 1048576
        if mi < 0.5 { return "\(Int((bytes / 1024).rounded()))Ki" }
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
        let age = Age.stamp(pod.metadata.creationTimestamp)
        let summary = PodStatusDerivation.summarize(pod)
        let req = PodStatusDerivation.requestedResources(pod)
        let restarts = summary.restarts
        return ResourceRow(
            kind: .pods,
            namespace: pod.metadata.namespace ?? "",
            name: pod.metadata.name,
            statusText: summary.reason,
            statusKind: summary.kind,
            cells: [
                "ready": summary.readyText,
                "restarts": "\(restarts)",
                "cpu": req.cpu,
                "mem": req.memory,
                "nodeName": pod.spec?.nodeName ?? "",   // not a column; joined to node arch by the view model
                "controlledBy": PodStatusDerivation.controllingWorkload(pod) ?? "",   // not a column; used by the delete confirm
                "age": age.text, "created": age.absolute,
            ],
            sortValues: [
                "ready": Double(summary.ready),
                "restarts": Double(restarts),
                "cpu": req.cpuMillis,
                "mem": req.memBytes,
                "age": age.seconds,
            ])
    }

    static func namespace(_ ns: K8sNamespace) -> ResourceRow {
        let age = Age.stamp(ns.metadata.creationTimestamp)
        let phase = ns.status?.phase ?? "Active"
        return ResourceRow(
            kind: .namespaces,
            namespace: "",
            name: ns.metadata.name,
            statusText: phase,
            statusKind: phase == "Active" ? .neutral : .terminating,
            cells: ["age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func node(_ node: K8sNode, usage: NodeUsage?) -> ResourceRow {
        let age = Age.stamp(node.metadata.creationTimestamp)
        // kubectl `printNode`: Ready / NotReady / Unknown (no Ready condition at all —
        // the node never reported), plus ",SchedulingDisabled" for a cordoned node.
        let conds = node.status?.conditions ?? []
        var text: String
        var kind: StatusKind
        switch conds.first(where: { $0.type == "Ready" })?.status {
        case "True": (text, kind) = ("Ready", .healthy)
        case nil, "Unknown": (text, kind) = ("Unknown", .unknown)
        default: (text, kind) = ("NotReady", .error)
        }
        if node.spec?.unschedulable == true {
            text += ",SchedulingDisabled"
            if kind == .healthy { kind = .warning }
        }
        // Pressure doesn't change kubectl's text, but a viewer should flag it.
        let pressure = conds.filter { ["MemoryPressure", "DiskPressure", "PIDPressure"].contains($0.type ?? "") && $0.status == "True" }
        if kind == .healthy, !pressure.isEmpty {
            kind = .warning
            text += "," + pressure.compactMap(\.type).joined(separator: ",")
        }
        return ResourceRow(
            kind: .nodes,
            namespace: "",
            name: node.metadata.name,
            statusText: text,
            statusKind: kind,
            cells: [
                "arch": node.status?.nodeInfo?.architecture ?? "—",
                "cpu": usage?.cpuText ?? "—",
                "cpupct": usage?.cpuPctText ?? "—",
                "mem": usage?.memText ?? "—",
                "mempct": usage?.memPctText ?? "—",
                "age": age.text, "created": age.absolute,
            ],
            sortValues: [
                "cpu": usage?.cpuMillis ?? 0,
                "cpupct": usage?.cpuPct ?? 0,
                "mem": usage?.memBytes ?? 0,
                "mempct": usage?.memPct ?? 0,
                "age": age.seconds,
            ])
    }

    static func event(_ e: K8sEvent) -> ResourceRow {
        let type = e.type ?? "Normal"
        let objText = [e.involvedObject?.kind, e.involvedObject?.name]
            .compactMap { $0 }.joined(separator: "/")
        // kubectl `printEvent`: events written through events.k8s.io (the scheduler,
        // kubelet, kcm) leave first/lastTimestamp + count empty and carry `eventTime` and
        // `series` instead — without this a FailedScheduling repeating for an hour shows
        // its first sighting, count 1, and sinks in a newest-first list.
        let first = e.firstTimestamp ?? e.eventTime ?? e.metadata.creationTimestamp
        let count = e.series?.count ?? max(1, e.count ?? 0)
        let source: String = {
            if let c = e.source?.component, !c.isEmpty {
                return e.source?.host.map { "\(c), \($0)" } ?? c
            }
            if let c = e.reportingComponent, !c.isEmpty {
                return e.reportingInstance.map { $0.isEmpty ? c : "\(c), \($0)" } ?? c
            }
            return "—"
        }()
        let firstDate = first.flatMap(Age.parse)
        let lastDate = (e.series?.lastObservedTime ?? e.lastTimestamp).flatMap(Age.parse) ?? firstDate
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
                "count": "\(count)",
                "type": type,
                "object": objText.isEmpty ? "—" : objText,
                "source": source,
                "first": firstDate.map { Age.timestamp($0) } ?? "—",
                "age": lastDate.map { Age.timestamp($0) } ?? "—",
            ],
            sortValues: [
                "count": Double(count),
                "age": lastDate.map { Age.seconds(since: $0) } ?? 0,
            ],
            uid: e.metadata.name)   // events' name is the reason → use the real name as identity
    }

    static func deployment(_ dep: K8sDeployment) -> ResourceRow {
        let age = Age.stamp(dep.metadata.creationTimestamp)
        let desired = dep.spec?.replicas ?? 0
        let ready = dep.status?.readyReplicas ?? 0
        let updated = dep.status?.updatedReplicas ?? 0
        let available = dep.status?.availableReplicas ?? 0
        let (text, kind) = deploymentStatus(dep, desired: desired, ready: ready, updated: updated, available: available)
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
                "age": age.text, "created": age.absolute,
            ],
            sortValues: [
                "ready": Double(ready), "uptodate": Double(updated), "available": Double(available),
                "desired": Double(desired),   // current replica count, for the scale dialog
                "age": age.seconds,
            ])
    }

    static func statefulSet(_ ss: K8sStatefulSet) -> ResourceRow {
        let age = Age.stamp(ss.metadata.creationTimestamp)
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
                "age": age.text, "created": age.absolute,
            ],
            sortValues: [
                "ready": Double(ready), "uptodate": Double(updated),
                "desired": Double(desired),   // current replica count, for the scale dialog
                "age": age.seconds,
            ])
    }

    static func replicaSet(_ rs: K8sReplicaSet) -> ResourceRow {
        let age = Age.stamp(rs.metadata.creationTimestamp)
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
                "age": age.text, "created": age.absolute,
            ],
            sortValues: [
                "desired": Double(desired), "current": Double(current), "ready": Double(ready),
                "age": age.seconds,
            ])
    }

    static func daemonSet(_ ds: K8sDaemonSet) -> ResourceRow {
        let age = Age.stamp(ds.metadata.creationTimestamp)
        let desired = ds.status?.desiredNumberScheduled ?? 0
        let current = ds.status?.currentNumberScheduled ?? 0
        let ready = ds.status?.numberReady ?? 0
        let updated = ds.status?.updatedNumberScheduled ?? 0
        let available = ds.status?.numberAvailable ?? ready
        // A DaemonSet isn't "scaled": zero desired means no node matches its
        // selector/tolerations — worth a look, not a calm "Scaled to 0".
        let (text, kind) = desired == 0
            ? ("No nodes match", .warning)
            : replicaStatus(desired: desired, ready: ready, available: available)
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
                "age": age.text, "created": age.absolute,
            ],
            sortValues: [
                "desired": Double(desired), "current": Double(current), "ready": Double(ready),
                "uptodate": Double(updated), "available": Double(available),
                "age": age.seconds,
            ])
    }

    static func configMap(_ cm: K8sConfigMap) -> ResourceRow {
        let age = Age.stamp(cm.metadata.creationTimestamp)
        let keys = (cm.data?.count ?? 0) + (cm.binaryData?.count ?? 0)
        return ResourceRow(
            kind: .configMaps, namespace: cm.metadata.namespace ?? "", name: cm.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["keys": "\(keys)", "age": age.text, "created": age.absolute],
            sortValues: ["keys": Double(keys), "age": age.seconds])
    }

    static func service(_ svc: K8sService) -> ResourceRow {
        let age = Age.stamp(svc.metadata.creationTimestamp)
        let ip = svc.spec?.clusterIP ?? "—"
        let ports = (svc.spec?.ports ?? []).map {
            ($0.port.map(String.init) ?? "?") + ($0.proto.map { "/\($0)" } ?? "")
        }.joined(separator: ", ")
        return ResourceRow(
            kind: .services, namespace: svc.metadata.namespace ?? "", name: svc.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["type": svc.spec?.type ?? "ClusterIP", "clusterIP": ip,
                    "ports": ports.isEmpty ? "—" : ports, "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func ingress(_ ing: K8sIngress) -> ResourceRow {
        let age = Age.stamp(ing.metadata.creationTimestamp)
        // kubectl prints a rule without a host as "*" (it matches every host).
        let hosts = (ing.spec?.rules ?? []).map { ($0.host ?? "").isEmpty ? "*" : $0.host! }.joined(separator: ", ")
        let addresses = (ing.status?.loadBalancer?.ingress ?? []).compactMap { $0.ip ?? $0.hostname }
        let address = addresses.isEmpty ? "—" : addresses.joined(separator: ",")
        return ResourceRow(
            kind: .ingresses, namespace: ing.metadata.namespace ?? "", name: ing.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["hosts": hosts.isEmpty ? "—" : hosts, "address": address,
                    "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func pvc(_ p: K8sPVC) -> ResourceRow {
        let age = Age.stamp(p.metadata.creationTimestamp)
        var phase = p.status?.phase ?? "Unknown"
        var kind: StatusKind
        switch phase {
        case "Bound": kind = .healthy
        case "Pending": kind = .pending
        case "Lost": kind = .error
        default: kind = .unknown
        }
        // A claim held by the `pvc-protection` finalizer (a pod still mounts it) sits
        // here for as long as that pod lives — kubectl shows it as Terminating.
        if p.metadata.deletionTimestamp != nil { (phase, kind) = ("Terminating", .terminating) }
        let capacity = p.status?.capacity?.storage ?? p.spec?.resources?.requests?.storage ?? "—"
        return ResourceRow(
            kind: .persistentVolumeClaims, namespace: p.metadata.namespace ?? "", name: p.metadata.name,
            statusText: phase, statusKind: kind,
            cells: ["capacity": capacity, "storageClass": p.spec?.storageClassName ?? "—",
                    "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func networkPolicy(_ np: K8sNetworkPolicy) -> ResourceRow {
        let age = Age.stamp(np.metadata.creationTimestamp)
        // Only a truly empty selector means every pod — `matchExpressions` alone used to
        // render as "all pods", making a narrow policy look namespace-wide.
        let selText = (np.spec?.podSelector).map { $0.isEmpty ? "all pods" : $0.formatted } ?? "all pods"
        let types = (np.spec?.policyTypes ?? []).joined(separator: ", ")
        return ResourceRow(
            kind: .networkPolicies, namespace: np.metadata.namespace ?? "", name: np.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["podSelector": selText, "policyTypes": types.isEmpty ? "—" : types,
                    "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func endpoints(_ ep: K8sEndpoints) -> ResourceRow {
        let age = Age.stamp(ep.metadata.creationTimestamp)
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
            cells: ["endpoints": summary, "count": "\(count)", "age": age.text, "created": age.absolute],
            sortValues: ["count": Double(count), "age": age.seconds])
    }

    static func pv(_ pv: K8sPV) -> ResourceRow {
        let age = Age.stamp(pv.metadata.creationTimestamp)
        var phase = pv.status?.phase ?? "Unknown"
        var kind: StatusKind
        switch phase {
        case "Bound", "Available": kind = .healthy
        case "Released": kind = .warning
        case "Failed": kind = .error
        case "Pending": kind = .pending
        default: kind = .unknown
        }
        if pv.metadata.deletionTimestamp != nil { (phase, kind) = ("Terminating", .terminating) }
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
                    "claim": claim, "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
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
        let age = Age.stamp(sc.metadata.creationTimestamp)
        let ann = sc.metadata.annotations ?? [:]
        let isDefault = ann["storageclass.kubernetes.io/is-default-class"] == "true"
            || ann["storageclass.beta.kubernetes.io/is-default-class"] == "true"   // legacy, still honored
        return ResourceRow(
            kind: .storageClasses, namespace: "", name: sc.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["provisioner": sc.provisioner ?? "—",
                    "reclaim": sc.reclaimPolicy ?? "Delete",
                    "binding": sc.volumeBindingMode ?? "Immediate",
                    "default": isDefault ? "✓" : "",
                    "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func pdb(_ pdb: K8sPDB) -> ResourceRow {
        let age = Age.stamp(pdb.metadata.creationTimestamp)
        let current = pdb.status?.currentHealthy ?? 0
        let desired = pdb.status?.desiredHealthy ?? 0
        let allowed = pdb.status?.disruptionsAllowed ?? 0
        let ok = current >= desired
        return ResourceRow(
            kind: .podDisruptionBudgets, namespace: pdb.metadata.namespace ?? "", name: pdb.metadata.name,
            statusText: ok ? "Healthy" : "Degraded", statusKind: ok ? .healthy : .warning,
            cells: ["minAvailable": pdb.spec?.minAvailable?.text ?? "—",
                    "maxUnavailable": pdb.spec?.maxUnavailable?.text ?? "—",
                    "allowed": "\(allowed)", "age": age.text, "created": age.absolute],
            sortValues: ["allowed": Double(allowed), "age": age.seconds])
    }

    static func job(_ j: K8sJob) -> ResourceRow {
        let age = Age.stamp(j.metadata.creationTimestamp)
        let succeeded = j.status?.succeeded ?? 0
        let failed = j.status?.failed ?? 0
        var kind: StatusKind = .pending
        var text = "Running"
        let conds = j.status?.conditions ?? []
        func isTrue(_ type: String) -> Bool { conds.contains { $0.type == type && $0.status == "True" } }
        // Between retries `active` is 0 while failures accumulate; until the controller
        // writes a Failed condition the Job is still trying — kubectl says Running.
        if isTrue("Complete") {
            kind = .healthy; text = "Complete"
        } else if isTrue("Failed") {
            kind = .error; text = "Failed"
        } else if j.spec?.suspend == true || isTrue("Suspended") {
            kind = .warning; text = "Suspended"
        } else if failed > 0 {
            kind = .warning; text = "Running (\(failed) failed)"
        }
        if j.metadata.deletionTimestamp != nil { (text, kind) = ("Terminating", .terminating) }
        // kubectl's COMPLETIONS: "N/M"; a work-queue Job (no completions, parallelism > 1)
        // is "N/1 of P".
        let completionsText: String
        if let completions = j.spec?.completions {
            completionsText = "\(succeeded)/\(completions)"
        } else if let p = j.spec?.parallelism, p > 1 {
            completionsText = "\(succeeded)/1 of \(p)"
        } else {
            completionsText = "\(succeeded)/1"
        }
        let duration = jobDuration(j.status?.startTime, j.status?.completionTime)
        return ResourceRow(
            kind: .jobs, namespace: j.metadata.namespace ?? "", name: j.metadata.name,
            statusText: text, statusKind: kind,
            cells: ["completions": completionsText, "duration": duration,
                    "age": age.text, "created": age.absolute],
            sortValues: ["completions": Double(succeeded), "age": age.seconds])
    }

    static func cronJob(_ c: K8sCronJob) -> ResourceRow {
        let age = Age.stamp(c.metadata.creationTimestamp)
        let suspended = c.spec?.suspend ?? false
        let lastRun = Age.format(c.status?.lastScheduleTime)
        return ResourceRow(
            kind: .cronJobs, namespace: c.metadata.namespace ?? "", name: c.metadata.name,
            statusText: "", statusKind: suspended ? .warning : .neutral,
            cells: ["schedule": c.spec?.schedule ?? "—", "suspend": suspended ? "Yes" : "No",
                    "lastRun": lastRun, "age": age.text, "created": age.absolute],
            sortValues: ["age": age.seconds])
    }

    static func serviceAccount(_ sa: K8sServiceAccount) -> ResourceRow {
        let age = Age.stamp(sa.metadata.creationTimestamp)
        let n = sa.secrets?.count ?? 0
        return ResourceRow(
            kind: .serviceAccounts, namespace: sa.metadata.namespace ?? "", name: sa.metadata.name,
            statusText: "", statusKind: .neutral,
            cells: ["secrets": "\(n)", "age": age.text, "created": age.absolute],
            sortValues: ["secrets": Double(n), "age": age.seconds])
    }

    static func hpa(_ h: K8sHPA) -> ResourceRow {
        let age = Age.stamp(h.metadata.creationTimestamp)
        let current = h.status?.currentReplicas ?? 0
        let desired = h.status?.desiredReplicas ?? current
        // An HPA that can't read its metrics (no metrics-server, wrong target) silently
        // stops scaling; its conditions are the only place that shows.
        let conds = h.status?.conditions ?? []
        let stuck = conds.first { ($0.type == "AbleToScale" || $0.type == "ScalingActive") && $0.status == "False" }
        let (text, kind): (String, StatusKind) = stuck.map { ($0.reason ?? "Inactive", .warning) }
            ?? (conds.isEmpty ? ("", .neutral) : ("Active", .healthy))
        return ResourceRow(
            kind: .horizontalPodAutoscalers, namespace: h.metadata.namespace ?? "", name: h.metadata.name,
            statusText: text, statusKind: kind,
            cells: ["min": "\(h.spec?.minReplicas ?? 0)", "max": "\(h.spec?.maxReplicas ?? 0)",
                    "replicas": "\(current)/\(desired)", "age": age.text, "created": age.absolute],
            sortValues: ["replicas": Double(current), "age": age.seconds])
    }

    private static func jobDuration(_ start: String?, _ end: String?) -> String {
        guard let start, let startDate = Age.parse(start) else { return "—" }
        let endDate = end.flatMap(Age.parse) ?? Date()
        return Age.humanize(max(0, endDate.timeIntervalSince(startDate)))
    }

    /// A Deployment's verdict from its conditions (what the controller itself
    /// concluded), falling back to replica arithmetic only when they say nothing:
    /// `ReplicaFailure` (quota / admission) and a blown progress deadline are errors;
    /// an in-flight rollout is Progressing — even when `ready ≥ desired` during a
    /// surge, and even when `ready == 0` seconds after creation.
    private static func deploymentStatus(_ dep: K8sDeployment, desired: Int, ready: Int,
                                         updated: Int, available: Int) -> (String, StatusKind) {
        let conds = dep.status?.conditions ?? []
        func cond(_ type: String) -> DeploymentCondition? { conds.first { $0.type == type } }
        if let rf = cond("ReplicaFailure"), rf.status == "True" { return (rf.reason ?? "ReplicaFailure", .error) }
        if let prog = cond("Progressing"), prog.status == "False" { return (prog.reason ?? "ProgressDeadlineExceeded", .error) }
        if desired == 0 { return ("Scaled to 0", .completed) }
        let rolling = cond("Progressing").map { $0.status == "True" && $0.reason != "NewReplicaSetAvailable" } ?? false
        if rolling || updated < desired { return ("Progressing", .pending) }
        if let av = cond("Available") {
            if av.status == "True" { return ready >= desired ? ("Available", .healthy) : ("Degraded", .warning) }
            return ready == 0 ? ("Unavailable", .error) : ("Degraded", .warning)
        }
        return replicaStatus(desired: desired, ready: ready, available: available)
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

/// Replicates kubectl's `printPod` (STATUS / READY / RESTARTS columns), including
/// native sidecars (init containers with `restartPolicy: Always`, GA in 1.33).
enum PodStatusDerivation {
    /// STATUS text + health, READY counts and RESTARTS — one pass, as kubectl does it.
    struct Summary {
        var reason: String
        var kind: StatusKind
        var ready: Int
        var total: Int
        var restarts: Int
        var readyText: String { "\(ready)/\(total)" }
    }

    /// An init container that keeps running beside the app (a native sidecar).
    static func isRestartable(_ c: NamedContainer?) -> Bool { c?.restartPolicy == "Always" }

    private static func condition(_ pod: K8sPod, _ type: String) -> PodCondition? {
        pod.status?.conditions?.first { $0.type == type }
    }

    static func summarize(_ pod: K8sPod) -> Summary {
        let status = pod.status
        let phase = status?.phase ?? "Unknown"
        var reason = phase
        if let r = status?.reason, !r.isEmpty { reason = r }
        // Scheduling gates hold a pod before the scheduler even looks at it.
        if (status?.conditions ?? []).contains(where: { $0.type == "PodScheduled" && $0.reason == "SchedulingGated" }) {
            reason = "SchedulingGated"
        }

        let initSpecs = Dictionary((pod.spec?.initContainers ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var total = (pod.spec?.containers ?? []).count
            + (pod.spec?.initContainers ?? []).filter(isRestartable).count
        var ready = 0
        var restarts = 0
        var sidecarRestarts = 0

        var initializing = false
        let initStatuses = status?.initContainerStatuses ?? []
        let initCount = pod.spec?.initContainers?.count ?? initStatuses.count
        for (i, ics) in initStatuses.enumerated() {
            restarts += ics.restartCount ?? 0
            let restartable = isRestartable(initSpecs[ics.name])
            if restartable { sidecarRestarts += ics.restartCount ?? 0 }
            if let term = ics.state?.terminated, (term.exitCode ?? 0) == 0 { continue }
            if restartable, ics.started == true {
                if ics.ready == true { ready += 1 }
                continue
            }
            if let term = ics.state?.terminated {
                if let r = term.reason, !r.isEmpty {
                    reason = "Init:\(r)"
                } else if let sig = term.signal, sig != 0 {
                    reason = "Init:Signal:\(sig)"
                } else {
                    reason = "Init:ExitCode:\(term.exitCode ?? 0)"
                }
            } else if let r = ics.state?.waiting?.reason, !r.isEmpty, r != "PodInitializing" {
                reason = "Init:\(r)"
            } else {
                reason = "Init:\(i)/\(initCount)"
            }
            initializing = true
            break
        }

        // Main containers are judged once init is done — or once the kubelet says the
        // pod is Initialized (a crash-looping sidecar mustn't hide the app's state).
        if !initializing || condition(pod, "Initialized")?.status == "True" {
            restarts = sidecarRestarts
            var hasRunning = false
            for cs in (status?.containerStatuses ?? []).reversed() {
                restarts += cs.restartCount ?? 0
                if let r = cs.state?.waiting?.reason, !r.isEmpty {
                    reason = r
                } else if let term = cs.state?.terminated {
                    if let r = term.reason, !r.isEmpty {
                        reason = r
                    } else if let sig = term.signal, sig != 0 {
                        reason = "Signal:\(sig)"
                    } else {
                        reason = "ExitCode:\(term.exitCode ?? 0)"
                    }
                } else if cs.ready == true, cs.state?.running != nil {
                    hasRunning = true
                    ready += 1
                }
            }
            // One container finished (a helper, or a Job's main container next to a
            // mesh proxy) while another still runs: not "Completed".
            if reason == "Completed" && hasRunning {
                reason = condition(pod, "Ready")?.status == "True" ? "Running" : "NotReady"
            }
        }

        if pod.metadata.deletionTimestamp != nil {
            if status?.reason == "NodeLost" {
                reason = "Unknown"
            } else if phase != "Succeeded" && phase != "Failed" {
                reason = "Terminating"   // a finished pod being deleted keeps Completed/Error
            }
        }
        if total == 0 { total = (status?.containerStatuses ?? []).count }

        // Healthy needs the pod's Ready condition, not just ready containers: readiness
        // gates (e.g. an AWS LB target registration) keep traffic off until they pass.
        let podReady = condition(pod, "Ready").map { $0.status == "True" } ?? (ready == total && total > 0)
        let kind = kind(for: reason, allReady: ready == total && total > 0 && podReady)
        return Summary(reason: reason, kind: kind, ready: ready, total: total, restarts: restarts)
    }

    static func kind(for reason: String, allReady: Bool) -> StatusKind {
        if reason == "Running" { return allReady ? .healthy : .warning }
        if reason == "Completed" || reason == "Succeeded" { return .completed }
        if reason == "Terminating" { return .terminating }
        if reason == "NotReady" { return .warning }

        let r = reason.lowercased()
        let errorMarkers = ["err", "backoff", "crashloop", "failed", "evicted",
                            "oomkilled", "exitcode", "signal", "invalid", "cannot",
                            "unknown", "deadlineexceeded"]
        if errorMarkers.contains(where: { r.contains($0) }) { return .error }

        if reason == "Pending" || reason == "ContainerCreating" || reason == "SchedulingGated"
            || reason == "PodInitializing" || r.hasPrefix("init:") {
            return .pending
        }
        return .warning
    }

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

    /// Plain-language "why is this pod (un)healthy" report plus restart/OOM
    /// forensics. Formatted as `Key: value` / header lines so DescribeFormatter
    /// colors it. Reads only status reasons/messages — never env vars or secrets.
    static func healthReport(_ pod: K8sPod) -> String {
        let summary = summarize(pod)
        let (reason, kind) = (summary.reason, summary.kind)
        let status = pod.status
        var notes: [String] = []

        if let bad = (status?.conditions ?? []).first(where: { $0.status == "False" && ($0.message?.isEmpty == false) }),
           (status?.containerStatuses ?? []).isEmpty || reason == "Pending" || reason == "SchedulingGated" {
            notes.append("Not scheduled/ready: \(bad.message ?? bad.reason ?? "—")")
        }
        let initSpecs = Dictionary((pod.spec?.initContainers ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for cs in status?.initContainerStatuses ?? [] {
            let label = isRestartable(initSpecs[cs.name]) ? "Sidecar" : "Init container"
            if let w = cs.state?.waiting, let r = w.reason, !r.isEmpty, r != "PodInitializing" {
                notes.append("\(label) “\(cs.name)”: \(explain(r)).")
            } else if let t = cs.state?.terminated, (t.exitCode ?? 0) != 0 {
                notes.append("\(label) “\(cs.name)” failed: \(terminationCause(t)).")
            } else if isRestartable(initSpecs[cs.name]), let note = notReadyNote(cs, label: label) {
                notes.append(note)
            }
        }
        for cs in status?.containerStatuses ?? [] {
            if let w = cs.state?.waiting, let r = w.reason, !r.isEmpty {
                notes.append("Container “\(cs.name)”: \(explain(r)).")
            } else if let t = cs.state?.terminated, t.reason != "Completed",
                      (t.exitCode ?? 0) != 0 || (t.signal ?? 0) != 0 {
                notes.append("Container “\(cs.name)”: \(terminationCause(t)).")
            } else if let note = notReadyNote(cs, label: "Container") {
                notes.append(note)
            }
            if let lt = cs.lastState?.terminated, (lt.exitCode ?? 0) != 0 || lt.reason == "OOMKilled" {
                let ago = Age.format(lt.finishedAt)
                let when = ago == "—" ? "" : ", \(ago) ago"
                notes.append("Container “\(cs.name)” previously \(terminationCause(lt))\(when) — restarted \(cs.restartCount ?? 0)×.")
            }
        }
        // Containers all ready but the pod isn't: a readiness gate (or a condition the
        // kubelet hasn't caught up on) — its message names what's missing.
        if reason == "Running" || reason == "NotReady",
           let rc = condition(pod, "Ready"), rc.status == "False",
           let msg = rc.message, !msg.isEmpty {
            notes.append("Pod not ready: \(msg)")
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
        lines += [row("Status", reason), row("Ready", summary.readyText), row("Restarts", "\(summary.restarts)"),
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

    /// The most common "Running 0/1": the process is up, but a probe holds it out of
    /// rotation. nil when the container is ready (or not running at all).
    private static func notReadyNote(_ cs: ContainerStatus, label: String) -> String? {
        guard cs.state?.running != nil, cs.ready == false else { return nil }
        if cs.started == false {
            return "\(label) “\(cs.name)” is running, but its startup probe hasn’t passed yet."
        }
        return "\(label) “\(cs.name)” is running but not ready — its readiness probe is failing (see Events)."
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

    /// The pod's effective request — what the scheduler reserves — not just the sum of
    /// `containers`: init containers run one at a time before them, so the pod needs
    /// `max(sum(app containers + sidecars), max over each plain init container +
    /// the sidecars started before it)`. A heavy migration init container would
    /// otherwise vanish from the column.
    static func requestedResources(_ pod: K8sPod) -> (cpu: String, memory: String, cpuMillis: Double, memBytes: Double) {
        var hasCPU = false, hasMem = false
        func req(_ c: NamedContainer) -> (cpu: Double, mem: Double) {
            var cpu = 0.0, mem = 0.0
            if let s = c.resources?.requests?.cpu, let m = Quantity.cpuMillicores(s) { cpu = m; hasCPU = true }
            if let s = c.resources?.requests?.memory, let b = Quantity.memoryBytes(s) { mem = b; hasMem = true }
            return (cpu, mem)
        }
        var cpuMillis = 0.0, memBytes = 0.0
        for c in pod.spec?.containers ?? [] {
            let r = req(c); cpuMillis += r.cpu; memBytes += r.mem
        }
        var sidecarCPU = 0.0, sidecarMem = 0.0, initCPU = 0.0, initMem = 0.0
        for c in pod.spec?.initContainers ?? [] {
            let r = req(c)
            if isRestartable(c) {
                sidecarCPU += r.cpu; sidecarMem += r.mem   // runs for the pod's whole life
            } else {
                initCPU = max(initCPU, sidecarCPU + r.cpu); initMem = max(initMem, sidecarMem + r.mem)
            }
        }
        cpuMillis = max(cpuMillis + sidecarCPU, initCPU)
        memBytes = max(memBytes + sidecarMem, initMem)
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
/// JSON `kind` back to our ResourceKind (for double-click navigation). Secrets are
/// NOT in the JSON query — that would pull every value into this process; they're
/// listed separately through the server-side Table (see `KubectlClient.secretRows`).
enum NamespaceInventory {
    static let queryKinds: [ResourceKind] = [
        .pods, .deployments, .statefulSets, .daemonSets, .replicaSets, .services,
        .ingresses, .configMaps, .serviceAccounts, .persistentVolumeClaims,
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

