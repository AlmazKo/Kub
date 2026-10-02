#!/usr/bin/env bash
# A throwaway demo cluster for screenshots and manual testing: a two-node
# minikube profile with a fake "acme" fleet (healthy services, a crash loop, an
# OOM kill, a bad image, a pod that can't schedule, jobs, a JVM, live logs and
# Prometheus metrics).
#
# Everything lives in its own kubeconfig, so ~/.kube/config — and every real
# context in it — is never read or written, and never shows in Kub's context
# picker while the demo runs.
#
#   scripts/demo-cluster.sh up      # create the cluster (Docker must be running) + deploy
#   scripts/demo-cluster.sh apply   # re-deploy the fleet, refresh rollout history
#   scripts/demo-cluster.sh open    # launch Kub against the demo kubeconfig only
#   scripts/demo-cluster.sh down    # delete the cluster and its kubeconfig
set -euo pipefail

PROFILE=kub-demo
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/demo" && pwd)"
export KUBECONFIG="${KUB_DEMO_KUBECONFIG:-$HOME/.kube/kub-demo.config}"
PROD_CTX=acme-prod-eu
STAGE_CTX=acme-staging-eu
NAMESPACES=(storefront payments platform data)

k() { kubectl --context "$PROD_CTX" "$@"; }

up() {
    minikube start -p "$PROFILE" --nodes 2 --cpus 2 --memory 2600 --kubernetes-version stable
    # Two names for the same cluster: a prod-looking one (exercises the prod-flagged
    # confirms) and a staging one, so the context picker has something to switch.
    kubectl config delete-context "$PROD_CTX" >/dev/null 2>&1 || true
    kubectl config rename-context "$PROFILE" "$PROD_CTX"
    kubectl config set-context "$STAGE_CTX" --cluster "$PROFILE" --user "$PROFILE" --namespace storefront
    kubectl config use-context "$PROD_CTX"
    apply
}

apply() {
    for ns in "${NAMESPACES[@]}"; do
        k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
        k -n "$ns" create configmap demo-scripts \
            --from-file="$DEMO_DIR/app.sh" --from-file="$DEMO_DIR/Inventory.java" \
            --dry-run=client -o yaml | k apply -f - >/dev/null
    done
    k apply -f "$DEMO_DIR/storefront.yaml" -f "$DEMO_DIR/payments.yaml" -f "$DEMO_DIR/platform.yaml"

    # A few rollouts so the History tab and roll-back have revisions to show.
    k -n storefront rollout status deploy/catalog-api --timeout 180s
    for v in 1.4.1 1.4.2; do
        k -n storefront set env deploy/catalog-api VERSION="$v" >/dev/null
        k -n storefront annotate deploy/catalog-api --overwrite \
            kubernetes.io/change-cause="Release catalog-api $v" >/dev/null
        k -n storefront rollout status deploy/catalog-api --timeout 180s
    done
    echo "Demo fleet deployed. Launch Kub with: $0 open"
}

open_kub() {
    local app="${1:-}"
    if [ -z "$app" ]; then
        local built
        built="$(cd "$DEMO_DIR/../.." && pwd)/.xcbuild/Build/Products/Debug/Kub.app"
        if [ -d "$built" ]; then app="$built"; else app=/Applications/Kub.app; fi
    fi
    # A running Kub would just re-activate with the real kubeconfig.
    pkill -f "Kub.app/Contents/MacOS/Kub" 2>/dev/null && sleep 1 || true
    open -n --env KUBECONFIG="$KUBECONFIG" "$app"
    echo "Kub launched against $KUBECONFIG ($app)"
}

down() {
    minikube delete -p "$PROFILE"
    rm -f "$KUBECONFIG"
}

case "${1:-}" in
    up) up ;;
    apply) apply ;;
    open) open_kub "${2:-}" ;;
    down) down ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
