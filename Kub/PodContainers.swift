import Foundation

/// Which container of a pod a process-level action (ps / exec / cp / shell) targets.
/// kubectl's default is the first container (or the `kubectl.kubernetes.io/default-container`
/// annotation), which in a pod with an injected sidecar is often the proxy, not the
/// app — and a PID read from one container's process list means nothing in another's
/// PID namespace, so every step of a diagnostic must name the same container.
enum PodContainers {
    /// Name fragments of injected / supporting containers that are never the app.
    private static let sidecarMarkers = [
        "istio-proxy", "linkerd-proxy", "envoy", "vault-agent", "consul", "fluent", "filebeat",
        "datadog", "otel", "cloud-sql-proxy", "cloudsql", "exporter", "sidecar", "-proxy",
        "-agent", "log-", "logging", "oauth2-proxy", "kube-rbac-proxy", "config-reloader",
    ]

    /// The main container's name: the `default-container` annotation if it names a real
    /// container, else the first container that doesn't look like a sidecar, else the
    /// first. nil for an empty spec (callers then leave the choice to kubectl).
    static func main(of pod: K8sPod) -> String? {
        let containers = pod.spec?.containers ?? []
        if let annotated = pod.metadata.annotations?["kubectl.kubernetes.io/default-container"],
           containers.contains(where: { $0.name == annotated }) {
            return annotated
        }
        guard containers.count > 1 else { return containers.first?.name }
        return containers.first { c in
            let n = c.name.lowercased()
            return !sidecarMarkers.contains { n.contains($0) }
        }?.name ?? containers.first?.name
    }
}
