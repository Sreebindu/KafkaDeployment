#!/usr/bin/env bash
# Deploys AutoMQ using Ceph RGW as S3 backend
# Usage: bash deploy-automq.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env
[[ -f "$SCRIPT_DIR/.env" ]] || { echo "ERROR: .env file not found"; exit 1; }
set -a; source "$SCRIPT_DIR/.env"; set +a

: "${CEPH_RGW_IP:?ERROR: CEPH_RGW_IP not set in .env}"
: "${CEPH_ACCESS_KEY:?ERROR: CEPH_ACCESS_KEY not set in .env}"
: "${CEPH_SECRET_KEY:?ERROR: CEPH_SECRET_KEY not set in .env}"
: "${HOST_VM_IP:?ERROR: HOST_VM_IP not set in .env}"

# Inject values into yamls
sed -i "s|<CEPH_RGW_IP>|${CEPH_RGW_IP}|g" \
    "$SCRIPT_DIR/automq-broker.yaml" \
    "$SCRIPT_DIR/automq-controller.yaml"
sed -i "s|<HOST_VM_IP>|${HOST_VM_IP}|g" \
    "$SCRIPT_DIR/automq-broker.yaml"

# ---------------------------------------------------------------------------
# 1. Create S3 buckets
# ---------------------------------------------------------------------------
echo "==> [1] Creating S3 buckets..."
bash "$SCRIPT_DIR/setup-s3-buckets.sh"

# ---------------------------------------------------------------------------
# 2. Create namespace + secrets
# ---------------------------------------------------------------------------
echo "==> [2] Creating namespace and secrets..."
kubectl create namespace automq 2>/dev/null || true
kubectl create secret generic automq-s3-credentials \
    --namespace automq \
    --from-literal=access_key="$CEPH_ACCESS_KEY" \
    --from-literal=secret_key="$CEPH_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 3. Deploy controller and broker
# ---------------------------------------------------------------------------
echo "==> [3] Deploying AutoMQ controller..."
kubectl apply -f "$SCRIPT_DIR/automq-controller.yaml"

echo "==> [4] Deploying AutoMQ broker..."
kubectl apply -f "$SCRIPT_DIR/automq-broker.yaml"

# ---------------------------------------------------------------------------
# 5. Wait for pods
# ---------------------------------------------------------------------------
echo "==> [5] Waiting for AutoMQ controller..."
kubectl -n automq rollout status deployment/automq-controller --timeout=300s

echo "==> [6] Waiting for AutoMQ broker..."
kubectl -n automq rollout status statefulset/automq-broker --timeout=300s

# ---------------------------------------------------------------------------
# 7. Get LB external IP and update advertised listener
# ---------------------------------------------------------------------------
echo "==> [7] Waiting for LoadBalancer external IP..."
EXTERNAL_IP=""
for i in $(seq 1 30); do
    EXTERNAL_IP=$(kubectl -n automq get svc automq-broker -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [[ -n "$EXTERNAL_IP" ]] && break
    echo "    waiting... ($i/30)"
    sleep 3
done
[[ -z "$EXTERNAL_IP" ]] && { echo "ERROR: LoadBalancer IP not assigned"; exit 1; }
echo "    LB IP: $EXTERNAL_IP"

# ---------------------------------------------------------------------------
# 8. Start socat to expose broker on host VM IP
# ---------------------------------------------------------------------------
echo "==> [8] Starting socat: $HOST_VM_IP:9094 -> $EXTERNAL_IP:9094"
pkill -f "socat.*TCP-LISTEN:9094" 2>/dev/null || true
sleep 1
nohup socat TCP-LISTEN:9094,fork,reuseaddr TCP:"$EXTERNAL_IP":9094 > /tmp/socat-kafka-9094.log 2>&1 &
echo "    socat PID: $!"

echo ""
echo "======================================"
echo " AutoMQ is up!"
echo " Internal (Conduktor): automq-broker.automq.svc.cluster.local:9092"
echo " External (other VMs): $HOST_VM_IP:9094"
echo "======================================"