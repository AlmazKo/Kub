import Foundation

// MARK: - Generic list

/// `kubectl get <res> -o json` returns `{ "apiVersion", "kind": "List", "items": [...] }`.
struct K8sList<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
}

// MARK: - Shared metadata

struct ObjectMeta: Decodable, Sendable {
    let name: String
    let namespace: String?
    let creationTimestamp: String?
    let deletionTimestamp: String?
    let labels: [String: String]?
    let annotations: [String: String]?
    let ownerReferences: [OwnerReference]?
}

struct OwnerReference: Decodable, Sendable {
    let kind: String?
    let name: String?
    let controller: Bool?
}

/// A Kubernetes int-or-string field (e.g. PDB minAvailable: `2` or `"50%"`).
struct IntOrString: Decodable, Sendable {
    let text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { text = String(i) }
        else { text = (try? c.decode(String.self)) ?? "" }
    }
}

/// Minimal envelope for a heterogeneous `get <kinds> -o json` list — each item
/// carries its own `kind` when multiple resource types are requested.
struct K8sObject: Decodable, Sendable {
    let kind: String?
    let metadata: ObjectMeta
}

// MARK: - Pods

struct K8sPod: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: PodSpec?
    let status: PodStatusRaw?
}

struct PodSpec: Decodable, Sendable {
    let nodeName: String?
    let containers: [NamedContainer]?
    let initContainers: [NamedContainer]?
    let volumes: [PodVolume]?
}

struct NamedContainer: Decodable, Sendable {
    let name: String
    let image: String?
    let restartPolicy: String?   // init containers only: "Always" = restartable (a sidecar)
    let ports: [ContainerPort]?
    let resources: ResourceRequirements?
    let volumeMounts: [VolumeMount]?
    let env: [EnvVar]?
    let envFrom: [EnvFromSource]?
    let livenessProbe: Probe?
    let readinessProbe: Probe?
    let startupProbe: Probe?
}

// MARK: - Pod volumes / env / probes (the "Mounts" tab)

struct PodVolume: Decodable, Sendable {
    let name: String
    let configMap: NamedVolumeSource?
    let secret: SecretVolumeSource?
    let persistentVolumeClaim: PVCVolumeSource?
    let hostPath: HostPathVolumeSource?
    let emptyDir: EmptyObject?
    let projected: EmptyObject?
    let downwardAPI: EmptyObject?
}
struct NamedVolumeSource: Decodable, Sendable { let name: String? }
struct SecretVolumeSource: Decodable, Sendable { let secretName: String? }
struct PVCVolumeSource: Decodable, Sendable { let claimName: String? }
struct HostPathVolumeSource: Decodable, Sendable { let path: String? }
struct EmptyObject: Decodable, Sendable {}

struct VolumeMount: Decodable, Sendable {
    let name: String
    let mountPath: String?
    let readOnly: Bool?
    let subPath: String?
}

struct EnvVar: Decodable, Sendable {
    let name: String
    let value: String?
    let valueFrom: EnvVarSource?
}
struct EnvVarSource: Decodable, Sendable {
    let configMapKeyRef: ObjectKeyRef?
    let secretKeyRef: ObjectKeyRef?
    let fieldRef: ObjectFieldRef?
    let resourceFieldRef: ResourceFieldRef?
}
struct ObjectKeyRef: Decodable, Sendable { let name: String?; let key: String? }
struct ObjectFieldRef: Decodable, Sendable { let fieldPath: String? }
struct ResourceFieldRef: Decodable, Sendable { let containerName: String?; let resource: String? }
struct EnvFromSource: Decodable, Sendable {
    let prefix: String?
    let configMapRef: NamedVolumeSource?
    let secretRef: NamedVolumeSource?
}

struct Probe: Decodable, Sendable {
    let httpGet: HTTPGetAction?
    let tcpSocket: TCPSocketAction?
    let exec: ExecAction?
    let initialDelaySeconds: Int?
    let periodSeconds: Int?
    let timeoutSeconds: Int?
    let failureThreshold: Int?
}
struct HTTPGetAction: Decodable, Sendable {
    let path: String?
    let port: IntOrString?
    let scheme: String?
}
struct TCPSocketAction: Decodable, Sendable { let port: IntOrString? }
struct ExecAction: Decodable, Sendable { let command: [String]? }

struct ContainerPort: Decodable, Sendable {
    let name: String?
    let containerPort: Int?
    let proto: String?
    enum CodingKeys: String, CodingKey {
        case name, containerPort
        case proto = "protocol"
    }
}

struct ResourceRequirements: Decodable, Sendable {
    let requests: ResourceList?
    let limits: ResourceList?
}

struct ResourceList: Decodable, Sendable {
    let cpu: String?
    let memory: String?
}

struct PodStatusRaw: Decodable, Sendable {
    let phase: String?
    let reason: String?
    let podIP: String?
    let startTime: String?
    let conditions: [PodCondition]?
    let containerStatuses: [ContainerStatus]?
    let initContainerStatuses: [ContainerStatus]?
}

struct PodCondition: Decodable, Sendable {
    let type: String?
    let status: String?
    let reason: String?
    let message: String?
}

struct ContainerStatus: Decodable, Sendable {
    let name: String
    let image: String?
    let ready: Bool?
    let started: Bool?               // startup probe passed (false while it's still pending)
    let restartCount: Int?
    let state: ContainerState?
    let lastState: ContainerState?   // previous run — where a recovered OOM/crash lives
}

struct ContainerState: Decodable, Sendable {
    let running: RunningState?
    let waiting: WaitingState?
    let terminated: TerminatedState?
}

struct RunningState: Decodable, Sendable {
    let startedAt: String?
}

struct WaitingState: Decodable, Sendable {
    let reason: String?
    let message: String?
}

struct TerminatedState: Decodable, Sendable {
    let reason: String?
    let exitCode: Int?
    let signal: Int?
    let message: String?
    let startedAt: String?
    let finishedAt: String?
}

// MARK: - Deployments

struct K8sDeployment: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: DeploymentSpec?
    let status: DeploymentStatusRaw?
}

struct DeploymentSpec: Decodable, Sendable {
    let replicas: Int?
    let strategy: StrategySpec?
}

/// `.spec.strategy` (Deployment) / `.spec.updateStrategy` (StatefulSet, DaemonSet) —
/// only `.type` matters for the restart-confirm note (RollingUpdate / OnDelete / Recreate).
struct StrategySpec: Decodable, Sendable { let type: String? }

struct DeploymentStatusRaw: Decodable, Sendable {
    let replicas: Int?
    let readyReplicas: Int?
    let updatedReplicas: Int?
    let availableReplicas: Int?
    let unavailableReplicas: Int?
    let conditions: [DeploymentCondition]?
}

struct DeploymentCondition: Decodable, Sendable {
    let type: String?
    let status: String?
    let reason: String?
    let message: String?
}

// MARK: - StatefulSets / ReplicaSets (share spec.replicas)

struct ReplicasSpec: Decodable, Sendable {
    let replicas: Int?
    let updateStrategy: StrategySpec?   // StatefulSet (ReplicaSet has none → nil)
}

struct K8sStatefulSet: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: ReplicasSpec?
    let status: StatefulSetStatus?
}

struct StatefulSetStatus: Decodable, Sendable {
    let replicas: Int?
    let readyReplicas: Int?
    let currentReplicas: Int?
    let updatedReplicas: Int?
    let availableReplicas: Int?
}

struct K8sReplicaSet: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: ReplicasSpec?
    let status: ReplicaSetStatus?
}

struct ReplicaSetStatus: Decodable, Sendable {
    let replicas: Int?
    let readyReplicas: Int?
    let availableReplicas: Int?
}

// MARK: - DaemonSets

struct K8sDaemonSet: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: DaemonSetSpec?
    let status: DaemonSetStatus?
}

struct DaemonSetSpec: Decodable, Sendable {
    let updateStrategy: StrategySpec?
}

struct DaemonSetStatus: Decodable, Sendable {
    let desiredNumberScheduled: Int?
    let currentNumberScheduled: Int?
    let numberReady: Int?
    let updatedNumberScheduled: Int?
    let numberAvailable: Int?
}

// MARK: - Config

struct K8sConfigMap: Decodable, Sendable {
    let metadata: ObjectMeta
    let data: [String: String]?
    let binaryData: [String: String]?
}

// MARK: - Network

struct K8sService: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: ServiceSpec?
}

struct ServiceSpec: Decodable, Sendable {
    let type: String?
    let clusterIP: String?
    let ports: [ServicePort]?
    let selector: [String: String]?   // which pods this Service fronts
}

struct ServicePort: Decodable, Sendable {
    let name: String?
    let port: Int?
    let targetPort: IntOrString?       // container port (number or name)
    let proto: String?
    enum CodingKeys: String, CodingKey {
        case name, port, targetPort
        case proto = "protocol"
    }
}

struct K8sIngress: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: IngressSpec?
    let status: IngressStatus?
}

struct IngressSpec: Decodable, Sendable {
    let rules: [IngressRule]?
}

struct IngressRule: Decodable, Sendable {
    let host: String?
}

struct IngressStatus: Decodable, Sendable {
    let loadBalancer: IngressLoadBalancer?
}

struct IngressLoadBalancer: Decodable, Sendable {
    let ingress: [IngressLBEntry]?
}

struct IngressLBEntry: Decodable, Sendable {
    let ip: String?
    let hostname: String?
}

// MARK: - Storage

struct K8sPVC: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: PVCSpec?
    let status: PVCStatus?
}

struct PVCSpec: Decodable, Sendable {
    let storageClassName: String?
    let resources: PVCResources?
}

struct PVCResources: Decodable, Sendable {
    let requests: PVCRequests?
}

struct PVCRequests: Decodable, Sendable {
    let storage: String?
}

struct PVCStatus: Decodable, Sendable {
    let phase: String?
    let capacity: PVCCapacity?
}

struct PVCCapacity: Decodable, Sendable {
    let storage: String?
}

// MARK: - Jobs

struct K8sJob: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: JobSpec?
    let status: JobStatus?
}

struct JobSpec: Decodable, Sendable {
    let completions: Int?
    let parallelism: Int?
    let suspend: Bool?
}

struct JobStatus: Decodable, Sendable {
    let succeeded: Int?
    let active: Int?
    let failed: Int?
    let startTime: String?
    let completionTime: String?
    let conditions: [JobCondition]?
}

struct JobCondition: Decodable, Sendable {
    let type: String?
    let status: String?
}

struct K8sCronJob: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: CronJobSpec?
    let status: CronJobStatus?
}

struct CronJobSpec: Decodable, Sendable {
    let schedule: String?
    let suspend: Bool?
}

struct CronJobStatus: Decodable, Sendable {
    let active: [ObjectReference]?
    let lastScheduleTime: String?
}

struct ObjectReference: Decodable, Sendable {
    let name: String?
}

// MARK: - ServiceAccounts / HPA

struct K8sServiceAccount: Decodable, Sendable {
    let metadata: ObjectMeta
    let secrets: [ObjectReference]?
}

struct K8sHPA: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: HPASpec?
    let status: HPAStatus?
}

struct HPASpec: Decodable, Sendable {
    let minReplicas: Int?
    let maxReplicas: Int?
}

struct HPAStatus: Decodable, Sendable {
    let currentReplicas: Int?
    let desiredReplicas: Int?
    let conditions: [HPACondition]?
}

/// `AbleToScale` / `ScalingActive` / `ScalingLimited` — a False `ScalingActive` is how
/// a missing metrics API or an unreadable target shows up.
struct HPACondition: Decodable, Sendable {
    let type: String?
    let status: String?
    let reason: String?
    let message: String?
}

// MARK: - Namespaces (cluster-scoped)

struct K8sNamespace: Decodable, Sendable {
    let metadata: ObjectMeta
    let status: NamespaceStatus?
}

struct NamespaceStatus: Decodable, Sendable {
    let phase: String?
}

// MARK: - Nodes (cluster-scoped)

struct K8sNode: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: NodeSpec?
    let status: NodeStatus?
}

struct NodeSpec: Decodable, Sendable {
    let unschedulable: Bool?      // cordoned → ",SchedulingDisabled"
    let taints: [NodeTaint]?
}

struct NodeTaint: Decodable, Sendable {
    let key: String?
    let value: String?
    let effect: String?           // NoSchedule / PreferNoSchedule / NoExecute
}

struct NodeStatus: Decodable, Sendable {
    let conditions: [NodeCondition]?
    let nodeInfo: NodeSystemInfo?
}

struct NodeSystemInfo: Decodable, Sendable {
    let architecture: String?     // amd64 / arm64 / …
    let operatingSystem: String?  // linux / windows
}

struct NodeCondition: Decodable, Sendable {
    let type: String?
    let status: String?
}

// MARK: - Events (core/v1)

/// Read through core/v1, but events emitted via events.k8s.io arrive with the *new*
/// fields instead: `eventTime` + `series` (count/lastObservedTime) in place of
/// `firstTimestamp`/`lastTimestamp`/`count` (which come back zero), and
/// `reportingComponent`/`reportingInstance` in place of `source`.
struct K8sEvent: Decodable, Sendable {
    let metadata: ObjectMeta
    let type: String?
    let reason: String?
    let action: String?
    let message: String?
    let count: Int?
    let firstTimestamp: String?
    let lastTimestamp: String?
    let eventTime: String?            // MicroTime — fractional seconds
    let series: EventSeries?
    let involvedObject: InvolvedObject?
    let source: EventSource?
    let reportingComponent: String?
    let reportingInstance: String?
}

struct EventSeries: Decodable, Sendable {
    let count: Int?
    let lastObservedTime: String?     // MicroTime
}

struct InvolvedObject: Decodable, Sendable {
    let kind: String?
    let name: String?
    let namespace: String?
}

struct EventSource: Decodable, Sendable {
    let component: String?
    let host: String?
}

// MARK: - kubeconfig (`kubectl config view -o json`)

struct KubeConfig: Decodable, Sendable {
    let contexts: [KubeContextEntry]?
    let currentContext: String?

    enum CodingKeys: String, CodingKey {
        case contexts
        case currentContext = "current-context"
    }
}

struct KubeContextEntry: Decodable, Sendable {
    let name: String
    let context: KubeContextDetail?
}

struct KubeContextDetail: Decodable, Sendable {
    let cluster: String?
    let namespace: String?
}

// MARK: - Network policies / endpoints

struct K8sNetworkPolicy: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: NetworkPolicySpec?
}
struct NetworkPolicySpec: Decodable, Sendable {
    let podSelector: LabelSelector?
    let policyTypes: [String]?
}
struct LabelSelector: Decodable, Sendable {
    let matchLabels: [String: String]?
    let matchExpressions: [LabelSelectorRequirement]?

    /// True when `matchLabels` is empty AND there are no expressions — selects everything.
    var isEmpty: Bool { (matchLabels ?? [:]).isEmpty && (matchExpressions ?? []).isEmpty }

    /// Full label-selector semantics: every matchLabels pair AND every expression must hold.
    func matches(_ labels: [String: String]) -> Bool {
        for (k, v) in matchLabels ?? [:] where labels[k] != v { return false }
        for req in matchExpressions ?? [] where !req.matches(labels) { return false }
        return true
    }

    /// `kubectl`-style rendering (`metav1.FormatLabelSelector`): `a=b,env in (x,y),tier`.
    var formatted: String {
        var parts = (matchLabels ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        for req in matchExpressions ?? [] {
            let values = (req.values ?? []).sorted().joined(separator: ",")
            switch req.operator {
            case "In": parts.append("\(req.key) in (\(values))")
            case "NotIn": parts.append("\(req.key) notin (\(values))")
            case "Exists": parts.append(req.key)
            case "DoesNotExist": parts.append("!\(req.key)")
            default: parts.append("\(req.key) \(req.operator) (\(values))")
            }
        }
        return parts.joined(separator: ",")
    }
}

struct LabelSelectorRequirement: Decodable, Sendable {
    let key: String
    let `operator`: String   // In / NotIn / Exists / DoesNotExist
    let values: [String]?

    func matches(_ labels: [String: String]) -> Bool {
        switch `operator` {
        case "In": return labels[key].map { (values ?? []).contains($0) } ?? false
        case "NotIn": return labels[key].map { !(values ?? []).contains($0) } ?? true
        case "Exists": return labels[key] != nil
        case "DoesNotExist": return labels[key] == nil
        default: return false
        }
    }
}

// MARK: - Prometheus Operator monitors (CRDs; absent on clusters without the operator)

/// `ServiceMonitor` — selects Services (by label); its endpoints name a Service port.
struct K8sServiceMonitor: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: MonitorSpec?
}

/// `PodMonitor` — selects Pods (by label); its endpoints name a container port.
struct K8sPodMonitor: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: MonitorSpec?
}

struct MonitorSpec: Decodable, Sendable {
    let selector: LabelSelector?
    /// Which namespaces the monitor selects targets from. Absent → the monitor's own
    /// namespace (the operator's default); `any: true` → every namespace.
    let namespaceSelector: MonitorNamespaceSelector?
    let endpoints: [MonitorEndpoint]?             // ServiceMonitor
    let podMetricsEndpoints: [MonitorEndpoint]?   // PodMonitor
}

struct MonitorNamespaceSelector: Decodable, Sendable {
    let any: Bool?
    let matchNames: [String]?

    /// Does a monitor living in `monitorNamespace` select targets in `target`?
    func selects(_ target: String, monitorNamespace: String) -> Bool {
        if any == true { return true }
        if let names = matchNames, !names.isEmpty { return names.contains(target) }
        return target == monitorNamespace
    }
}

struct MonitorEndpoint: Decodable, Sendable {
    let port: String?             // port NAME (Service port for SM, container port for PM)
    let targetPort: IntOrString?  // explicit target (number or name), overrides `port`
    let path: String?
    let scheme: String?
}

struct K8sEndpoints: Decodable, Sendable {
    let metadata: ObjectMeta
    let subsets: [EndpointSubset]?
}
struct EndpointSubset: Decodable, Sendable {
    let addresses: [EndpointAddress]?
    let ports: [EndpointPort]?
}
struct EndpointAddress: Decodable, Sendable { let ip: String? }
struct EndpointPort: Decodable, Sendable {
    let port: Int?
    let proto: String?
    enum CodingKeys: String, CodingKey { case port; case proto = "protocol" }
}

// MARK: - Persistent volumes / storage classes (cluster-scoped)

struct K8sPV: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: PVSpec?
    let status: PVStatus?
}
struct PVSpec: Decodable, Sendable {
    let capacity: PVCapacity?
    let accessModes: [String]?
    let persistentVolumeReclaimPolicy: String?
    let storageClassName: String?
    let claimRef: PVClaimRef?
}
struct PVCapacity: Decodable, Sendable { let storage: String? }
struct PVClaimRef: Decodable, Sendable { let namespace: String?; let name: String? }
struct PVStatus: Decodable, Sendable { let phase: String? }

struct K8sStorageClass: Decodable, Sendable {
    let metadata: ObjectMeta
    let provisioner: String?
    let reclaimPolicy: String?
    let volumeBindingMode: String?
}

// MARK: - Pod disruption budgets

struct K8sPDB: Decodable, Sendable {
    let metadata: ObjectMeta
    let spec: PDBSpec?
    let status: PDBStatus?
}
struct PDBSpec: Decodable, Sendable {
    let minAvailable: IntOrString?
    let maxUnavailable: IntOrString?
}
struct PDBStatus: Decodable, Sendable {
    let currentHealthy: Int?
    let desiredHealthy: Int?
    let disruptionsAllowed: Int?
    let expectedPods: Int?
}
