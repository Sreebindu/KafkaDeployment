#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER="${KIND_CLUSTER:-automq}"
AUTOMQ_NS="automq"
CONDUKTOR_NS="conduktor"
RENDER_DIR="$SCRIPT_DIR/.rendered"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

load_env() {
    [[ -f "$SCRIPT_DIR/.env" ]] || die ".env not found. Copy .env.example to .env and fill credentials."
    chmod 600 "$SCRIPT_DIR/.env" || true
    set -a
    source "$SCRIPT_DIR/.env"
    set +a

    : "${CEPH_RGW_IP:?CEPH_RGW_IP missing}"
    : "${CEPH_ACCESS_KEY:?CEPH_ACCESS_KEY missing}"
    : "${CEPH_SECRET_KEY:?CEPH_SECRET_KEY missing}"
    : "${HOST_VM_IP:?HOST_VM_IP missing}"
    : "${KAFKA_EXTERNAL_HOST:?KAFKA_EXTERNAL_HOST missing}"
    : "${KAFKA_EXTERNAL_PORT:?KAFKA_EXTERNAL_PORT missing}"
}

precheck() {
    for c in docker kind kubectl aws curl sed; do
        have "$c" || die "Missing required command: $c"
    done

    docker info >/dev/null 2>&1 || die "Docker daemon is not accessible"

    for f in kind-cluster.yaml automq-controller.yaml automq-broker.yaml conduktor.yaml setup-s3-buckets.sh; do
        [[ -f "$SCRIPT_DIR/$f" ]] || die "Missing file: $f"
    done

    load_env
    ok "Prerequisites and configuration look good"
}

kernel_setup() {
    sudo modprobe overlay
    sudo modprobe bridge || true
    sudo modprobe br_netfilter
    sudo modprobe nf_conntrack || true
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
    sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

ceph_check() {
    load_env
    local endpoint="http://${CEPH_RGW_IP}:7480"

    curl -fsSI --connect-timeout 5 "$endpoint" >/dev/null \
        || die "Ceph RGW not reachable at $endpoint"

    AWS_ACCESS_KEY_ID="$CEPH_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$CEPH_SECRET_KEY" \
    aws --endpoint-url "$endpoint" --region us-east-1 s3 ls >/dev/null \
        || die "Ceph RGW credentials failed"

    ok "Ceph RGW reachable"
}

render_manifests() {
    load_env
    rm -rf "$RENDER_DIR"
    mkdir -p "$RENDER_DIR"

    for f in automq-controller.yaml automq-broker.yaml; do
        sed \
          -e "s|__CEPH_RGW_IP__|${CEPH_RGW_IP}|g" \
          -e "s|__KAFKA_EXTERNAL_HOST__|${KAFKA_EXTERNAL_HOST}|g" \
          -e "s|__KAFKA_EXTERNAL_PORT__|${KAFKA_EXTERNAL_PORT}|g" \
          "$SCRIPT_DIR/$f" > "$RENDER_DIR/$f"
    done

    cp "$SCRIPT_DIR/conduktor.yaml" "$RENDER_DIR/conduktor.yaml"
    ok "Rendered manifests in $RENDER_DIR"
}

cluster_exists() {
    kind get clusters 2>/dev/null | grep -Fxq "$KIND_CLUSTER"
}

create_cluster() {
    if cluster_exists; then
        ok "KIND cluster '$KIND_CLUSTER' already exists"
    else
        kind create cluster --name "$KIND_CLUSTER" --config "$SCRIPT_DIR/kind-cluster.yaml"
    fi

    kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

create_secret() {
    load_env
    kubectl create namespace "$AUTOMQ_NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic automq-s3-credentials \
      -n "$AUTOMQ_NS" \
      --from-literal=access_key="$CEPH_ACCESS_KEY" \
      --from-literal=secret_key="$CEPH_SECRET_KEY" \
      --dry-run=client -o yaml | kubectl apply -f -
}

install() {
    precheck
    kernel_setup
    ceph_check
    create_cluster
    bash "$SCRIPT_DIR/setup-s3-buckets.sh"
    render_manifests
    create_secret

    kubectl apply -f "$RENDER_DIR/automq-controller.yaml"
    kubectl apply -f "$RENDER_DIR/automq-broker.yaml"

    kubectl rollout status deployment/automq-controller -n automq --timeout=300s
    kubectl rollout status statefulset/automq-broker -n automq --timeout=300s

    kubectl create namespace conduktor --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$RENDER_DIR/conduktor.yaml"

    kubectl rollout status deployment/conduktor-postgres -n conduktor --timeout=300s || true
    kubectl rollout status deployment/conduktor-console -n conduktor --timeout=300s || true

    status
}

status() {
    printf '\n=== KIND ===\n'
    kind get clusters || true
    printf '\n=== NODES ===\n'
    kubectl get nodes -o wide || true
    printf '\n=== AUTOMQ ===\n'
    kubectl get all -n automq -o wide || true
    printf '\n=== AUTOMQ SERVICES ===\n'
    kubectl get svc -n automq -o wide || true
    printf '\n=== CONDUKTOR ===\n'
    kubectl get all -n conduktor -o wide || true
    printf '\n=== CONDUKTOR SERVICES ===\n'
    kubectl get svc -n conduktor -o wide || true
}

uninstall() {
    warn "Removing AutoMQ and Conduktor namespaces. KIND cluster and Ceph data will be retained."
    kubectl delete namespace automq --ignore-not-found --wait=true
    kubectl delete namespace conduktor --ignore-not-found --wait=true
    ok "Workloads removed"
}

uninstall_all() {
    warn "Deleting KIND cluster '$KIND_CLUSTER'. Ceph buckets/data are NOT deleted."
    if cluster_exists; then
        kind delete cluster --name "$KIND_CLUSTER"
    fi
    ok "KIND cluster removal complete"
}

case "${1:-}" in
    precheck) precheck ;;
    ceph-check) precheck; ceph_check ;;
    install) install ;;
    status) status ;;
    uninstall) uninstall ;;
    uninstall-all) uninstall_all ;;
    *)
        cat <<EOF
Usage: $0 {precheck|ceph-check|install|status|uninstall|uninstall-all}
EOF
        exit 1
        ;;
esac
