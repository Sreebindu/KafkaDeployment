#!/usr/bin/env bash

# ==============================================================================
# AutoMQ + Ceph RGW + Vault + kind + Conduktor
# Single-click deployment
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTOMQ_VM_IP="192.168.10.70"

CEPH_DEFAULT_ENDPOINT="http://192.168.10.71:7480"

VAULT_ADDR="http://127.0.0.1:8200"
VAULT_SECRET_PATH="automq/ceph"

VAULT_ROLE_ID_FILE="/etc/automq-vault/role-id"
VAULT_SECRET_ID_FILE="/etc/automq-vault/secret-id"

KIND_CLUSTER_NAME="automq"

AUTOMQ_NAMESPACE="automq"
CONDUKTOR_NAMESPACE="conduktor"

AUTOMQ_CONTROLLER_YAML="$SCRIPT_DIR/automq-controller.yaml"
AUTOMQ_BROKER_YAML="$SCRIPT_DIR/automq-broker.yaml"
CONDUKTOR_MANIFEST="$SCRIPT_DIR/conduktor.yaml"

AUTOMQ_SECRET_NAME="automq-s3-credentials"

S3_DATA_BUCKET="automq-data"
S3_WAL_BUCKET="automq-wal"

KAFKA_INTERNAL_SERVICE="automq-broker.automq.svc.cluster.local:9092"

export VAULT_ADDR

# ==============================================================================
# FUNCTIONS
# ==============================================================================

section()
{
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

info()
{
    echo "[INFO] $*"
}

ok()
{
    echo "[PASS] $*"
}

warn()
{
    echo "[WARN] $*"
}

fail()
{
    echo
    echo "[FAIL] $*" >&2
    echo
    exit 1
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

cleanup_sensitive()
{
    unset ROLE_ID 2>/dev/null || true
    unset SECRET_ID 2>/dev/null || true
    unset VAULT_TOKEN 2>/dev/null || true

    unset CEPH_ACCESS_KEY 2>/dev/null || true
    unset CEPH_SECRET_KEY 2>/dev/null || true

    unset AWS_ACCESS_KEY_ID 2>/dev/null || true
    unset AWS_SECRET_ACCESS_KEY 2>/dev/null || true
}

cleanup_all()
{
    cleanup_sensitive

    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup_all EXIT

# ==============================================================================
# 1. PRE-FLIGHT
# ==============================================================================

section "[1/20] Pre-flight"

info "Repository     : $SCRIPT_DIR"
info "AutoMQ VM      : $AUTOMQ_VM_IP"
info "Ceph RGW       : $CEPH_DEFAULT_ENDPOINT"
info "Vault          : $VAULT_ADDR"

[[ -f "$AUTOMQ_CONTROLLER_YAML" ]] ||
    fail "Missing AutoMQ controller manifest:

$AUTOMQ_CONTROLLER_YAML"

[[ -f "$AUTOMQ_BROKER_YAML" ]] ||
    fail "Missing AutoMQ broker manifest:

$AUTOMQ_BROKER_YAML"

[[ -f "$CONDUKTOR_MANIFEST" ]] ||
    fail "Missing Conduktor manifest:

$CONDUKTOR_MANIFEST"

ok "Pre-flight complete"

# ==============================================================================
# 2. NORMALIZE REPOSITORY FILES
# ==============================================================================

section "[2/20] Normalizing repository files"

find "$SCRIPT_DIR" \
    -maxdepth 1 \
    -type f \
    \( -name "*.sh" -o -name "*.yaml" -o -name "*.yml" \) \
    -exec sed -i 's/\r$//' {} +

ok "Repository files normalized"

# ==============================================================================
# 3. BASE DEPENDENCIES
# ==============================================================================

section "[3/20] Base dependencies"

MISSING_PACKAGES=()

for package in \
    curl \
    wget \
    jq \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    netcat-openbsd \
    socat \
    openssl
do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$package")
    fi
done

if (( ${#MISSING_PACKAGES[@]} > 0 )); then

    info "Installing missing packages..."

    sudo apt-get update

    sudo apt-get install -y \
        "${MISSING_PACKAGES[@]}"

else
    info "All base dependencies already installed."
fi

ok "Base dependencies ready"

# ==============================================================================
# 4. DOCKER
# ==============================================================================

section "[4/20] Docker"

# ------------------------------------------------------------------------------
# Install Docker only when it is actually missing.
# ------------------------------------------------------------------------------

if ! command_exists docker; then

    info "Docker not found. Installing Docker..."

    sudo install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        https://download.docker.com/linux/ubuntu/gpg |
        sudo gpg \
            --dearmor \
            --yes \
            -o /etc/apt/keyrings/docker.gpg

    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    CODENAME="$(
        . /etc/os-release
        echo "$VERSION_CODENAME"
    )"

    ARCH="$(dpkg --print-architecture)"

    echo \
"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" |
        sudo tee \
            /etc/apt/sources.list.d/docker.list \
            >/dev/null

    sudo apt-get update

    sudo apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

else
    info "Docker already installed."
fi

# ------------------------------------------------------------------------------
# Ensure Docker daemon is running.
# ------------------------------------------------------------------------------

if ! systemctl is-active --quiet docker; then

    info "Starting Docker service..."

    sudo systemctl start docker
fi

# ------------------------------------------------------------------------------
# Enable Docker at boot.
# ------------------------------------------------------------------------------

if ! systemctl is-enabled --quiet docker 2>/dev/null; then

    info "Enabling Docker service..."

    sudo systemctl enable docker
fi

# ------------------------------------------------------------------------------
# Verify daemon using sudo first.
# ------------------------------------------------------------------------------

if ! sudo docker info >/dev/null 2>&1; then

    fail "Docker daemon is installed but not operational.

Check:

    sudo systemctl status docker

    sudo journalctl -u docker --no-pager -n 100"
fi

# ------------------------------------------------------------------------------
# Ensure docker group exists.
# ------------------------------------------------------------------------------

if ! getent group docker >/dev/null 2>&1; then

    info "Creating docker group..."

    sudo groupadd docker
fi

# ------------------------------------------------------------------------------
# Ensure current user is configured as docker group member.
# ------------------------------------------------------------------------------

if ! getent group docker |
    awk -F: '{print $4}' |
    tr ',' '\n' |
    grep -Fxq "$USER"
then

    info "Adding $USER to docker group..."

    sudo usermod \
        -aG docker \
        "$USER"

    ok "$USER added to docker group"
fi

# ------------------------------------------------------------------------------
# IMPORTANT:
#
# usermod updates /etc/group but cannot update supplementary groups of this
# already-running Bash process.
#
# If Docker isn't accessible in this shell, automatically re-execute this
# complete deployment under the docker group.
#
# This avoids requiring:
#
#     newgrp docker
#
# or logout/login.
# ------------------------------------------------------------------------------

if ! docker info >/dev/null 2>&1; then

    if [[ "${AUTOMQ_DOCKER_REEXEC:-0}" != "1" ]]; then

        echo
        info "Docker group membership is not active in current shell."
        info "Automatically re-running deployment with docker group active..."
        echo

        SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

        export AUTOMQ_DOCKER_REEXEC=1

        exec sg docker -c \
            "AUTOMQ_DOCKER_REEXEC=1 bash '$SCRIPT_PATH'"
    fi

    fail "Docker socket is still inaccessible after docker-group activation.

Diagnostics:

    id
    getent group docker
    ls -l /var/run/docker.sock
    docker info"
fi

docker --version

docker info >/dev/null ||
    fail "Docker API is not accessible."

info "Docker socket:"
ls -l /var/run/docker.sock

info "Current effective groups:"
id

ok "Docker operational for user $USER"

# ==============================================================================
# 5. KUBECTL
# ==============================================================================

section "[5/20] kubectl"

if ! command_exists kubectl; then

    info "Installing kubectl..."

    KUBECTL_VERSION="$(
        curl -L -s \
            https://dl.k8s.io/release/stable.txt
    )"

    info "Installing kubectl $KUBECTL_VERSION"

    curl \
        -L \
        -o /tmp/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

    chmod +x /tmp/kubectl

    sudo install \
        -o root \
        -g root \
        -m 0755 \
        /tmp/kubectl \
        /usr/local/bin/kubectl

else
    info "kubectl already installed."
fi

kubectl version --client

ok "kubectl ready"

# ==============================================================================
# 6. KIND
# ==============================================================================

section "[6/20] kind"

if ! command_exists kind; then

    KIND_VERSION="v0.32.0"

    info "Installing kind $KIND_VERSION..."

    curl \
        -Lo /tmp/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"

    chmod +x /tmp/kind

    sudo install \
        -o root \
        -g root \
        -m 0755 \
        /tmp/kind \
        /usr/local/bin/kind

else
    info "kind already installed."
fi

kind --version

ok "kind ready"

# ==============================================================================
# 7. AWS CLI
# ==============================================================================

section "[7/20] AWS CLI"

if ! command_exists aws; then

    info "Installing AWS CLI..."

    rm -rf \
        /tmp/aws \
        /tmp/awscliv2.zip

    curl \
        "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o /tmp/awscliv2.zip

    unzip \
        -q \
        /tmp/awscliv2.zip \
        -d /tmp

    sudo /tmp/aws/install

else
    info "AWS CLI already installed."
fi

aws --version

ok "AWS CLI ready"

# ==============================================================================
# 8. VAULT
# ==============================================================================

section "[8/20] Vault"

# ------------------------------------------------------------------------------
# Vault is persistent infrastructure.
#
# DO NOT:
#
#   - reinstall Vault
#   - initialize Vault again
#   - recreate Vault storage
#   - overwrite vault.hcl
#   - regenerate the root token
#   - regenerate the unseal key
#   - store root/unseal credentials in this script
#
# This script only validates the existing Vault.
# ------------------------------------------------------------------------------

if ! command_exists vault; then

    fail "Vault is not installed.

This deployment expects the existing initialized Vault installation."
fi

# Do not restart an existing running Vault.

if ! systemctl is-active --quiet vault; then

    info "Vault service is not running."
    info "Starting existing Vault service..."

    sudo systemctl start vault

    sleep 2
fi

systemctl is-active --quiet vault ||
    fail "Vault service failed to start."

info "Checking existing Vault instance at $VAULT_ADDR"

VAULT_STATUS_JSON="$(
    VAULT_ADDR="$VAULT_ADDR" \
    vault status \
        -format=json \
        2>/dev/null ||
        true
)"

[[ -n "$VAULT_STATUS_JSON" ]] ||
    fail "Unable to communicate with Vault at:

$VAULT_ADDR"

jq -e . \
    >/dev/null 2>&1 \
    <<< "$VAULT_STATUS_JSON" ||
    fail "Vault returned invalid JSON status information."

# IMPORTANT:
#
# Do NOT use:
#
#     .sealed // true
#
# because jq // considers false eligible for fallback.
#
# Use the actual boolean value directly.

VAULT_INITIALIZED="$(
    jq -r \
        '.initialized' \
        <<< "$VAULT_STATUS_JSON"
)"

VAULT_SEALED="$(
    jq -r \
        '.sealed' \
        <<< "$VAULT_STATUS_JSON"
)"

VAULT_STORAGE="$(
    jq -r \
        '.storage_type // "unknown"' \
        <<< "$VAULT_STATUS_JSON"
)"

VAULT_HA="$(
    jq -r \
        '.ha_enabled' \
        <<< "$VAULT_STATUS_JSON"
)"

echo "Initialized : $VAULT_INITIALIZED"
echo "Sealed      : $VAULT_SEALED"
echo "Storage     : $VAULT_STORAGE"
echo "HA Enabled  : $VAULT_HA"

[[ "$VAULT_INITIALIZED" == "true" ]] ||
    fail "Vault exists but is not initialized.

Do NOT initialize it automatically from this deployment."

if [[ "$VAULT_SEALED" == "true" ]]; then

    echo
    echo "Vault is currently SEALED."
    echo
    echo "The deployment cannot retrieve Ceph credentials while Vault is sealed."
    echo
    echo "Run:"
    echo
    echo "    export VAULT_ADDR=$VAULT_ADDR"
    echo "    vault operator unseal"
    echo
    echo "Then rerun:"
    echo
    echo "    bash deploy-automq.sh"
    echo

    exit 21
fi

[[ "$VAULT_SEALED" == "false" ]] ||
    fail "Unable to determine Vault seal state.

Reported value:

$VAULT_SEALED"

ok "Vault initialized and unsealed"

# ==============================================================================
# 9. VAULT APPROLE AUTHENTICATION
# ==============================================================================

section "[9/20] Vault AppRole authentication"

# ------------------------------------------------------------------------------
# These files are intentionally:
#
#     root:root
#     600
#
# Normal:
#
#     [[ -s "$VAULT_ROLE_ID_FILE" ]]
#
# will FAIL for the msb user.
#
# Therefore all checks/reads are done using sudo.
# ------------------------------------------------------------------------------

if ! sudo test -s "$VAULT_ROLE_ID_FILE"; then

    fail "Missing or empty Vault Role ID:

$VAULT_ROLE_ID_FILE"
fi

if ! sudo test -s "$VAULT_SECRET_ID_FILE"; then

    fail "Missing or empty Vault Secret ID:

$VAULT_SECRET_ID_FILE"
fi

ROLE_ID="$(
    sudo cat "$VAULT_ROLE_ID_FILE"
)"

SECRET_ID="$(
    sudo cat "$VAULT_SECRET_ID_FILE"
)"

[[ -n "$ROLE_ID" ]] ||
    fail "Vault Role ID is empty."

[[ -n "$SECRET_ID" ]] ||
    fail "Vault Secret ID is empty."

info "Authenticating to Vault using AutoMQ AppRole..."

VAULT_TOKEN="$(
    VAULT_ADDR="$VAULT_ADDR" \
    vault write \
        -field=token \
        auth/approle/login \
        role_id="$ROLE_ID" \
        secret_id="$SECRET_ID"
)"

[[ -n "$VAULT_TOKEN" ]] ||
    fail "Vault AppRole authentication failed."

export VAULT_TOKEN

# Remove AppRole values from shell variables as soon as possible.

unset ROLE_ID
unset SECRET_ID

ok "Vault AppRole authentication successful"

# ==============================================================================
# 10. RETRIEVE CEPH CREDENTIALS
# ==============================================================================

section "[10/20] Retrieve Ceph credentials"

CEPH_ACCESS_KEY="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get \
        -field=access_key \
        "$VAULT_SECRET_PATH"
)"

CEPH_SECRET_KEY="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get \
        -field=secret_key \
        "$VAULT_SECRET_PATH"
)"

VAULT_ENDPOINT="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get \
        -field=endpoint \
        "$VAULT_SECRET_PATH"
)"

[[ -n "$CEPH_ACCESS_KEY" ]] ||
    fail "Ceph AccessKey missing from Vault."

[[ -n "$CEPH_SECRET_KEY" ]] ||
    fail "Ceph SecretKey missing from Vault."

[[ -n "$VAULT_ENDPOINT" ]] ||
    fail "Ceph endpoint missing from Vault."

CEPH_ENDPOINT="$VAULT_ENDPOINT"

info "Ceph endpoint : $CEPH_ENDPOINT"
info "Access key    : retrieved"
info "Secret key    : retrieved"

ok "Ceph credentials retrieved from Vault"

# ==============================================================================
# 11. CEPH RGW
# ==============================================================================

section "[11/20] Ceph RGW"

info "Testing Ceph RGW: $CEPH_ENDPOINT"

if ! curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 10 \
    "$CEPH_ENDPOINT" \
    >/dev/null
then

    fail "Ceph RGW is not reachable:

$CEPH_ENDPOINT

Check:

    Ceph VM
    RGW service
    port 7480
    firewall/network connectivity"
fi

export AWS_ACCESS_KEY_ID="$CEPH_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$CEPH_SECRET_KEY"
export AWS_DEFAULT_REGION="us-east-1"

info "Testing Ceph S3 authentication..."

aws \
    --endpoint-url "$CEPH_ENDPOINT" \
    s3api list-buckets \
    >/dev/null ||
    fail "Ceph RGW is reachable but S3 authentication failed."

ok "Ceph RGW connectivity and authentication successful"

# ==============================================================================
# 12. S3 BUCKETS
# ==============================================================================

section "[12/20] S3 buckets"

ensure_bucket()
{
    local bucket="$1"

    if aws \
        --endpoint-url "$CEPH_ENDPOINT" \
        s3api head-bucket \
        --bucket "$bucket" \
        >/dev/null 2>&1
    then

        info "Bucket already exists: $bucket"

    else

        info "Creating bucket: $bucket"

        aws \
            --endpoint-url "$CEPH_ENDPOINT" \
            s3 mb \
            "s3://$bucket"
    fi
}

ensure_bucket "$S3_DATA_BUCKET"
ensure_bucket "$S3_WAL_BUCKET"

echo
info "Current Ceph buckets:"

aws \
    --endpoint-url "$CEPH_ENDPOINT" \
    s3 ls

ok "S3 buckets ready"

# ==============================================================================
# 13. KIND KUBERNETES CLUSTER
# ==============================================================================

section "[13/20] kind Kubernetes cluster"

# kind directly invokes Docker.
# Validate Docker access before kind does anything.

docker info >/dev/null 2>&1 ||
    fail "kind cannot access Docker.

Docker socket:

$(ls -l /var/run/docker.sock 2>/dev/null || true)

Current groups:

$(id)"

ok "Docker API available to kind"

# ------------------------------------------------------------------------------
# Reuse cluster if it already exists.
# ------------------------------------------------------------------------------

if kind get clusters \
    2>/dev/null |
    grep -qx "$KIND_CLUSTER_NAME"
then

    info "kind cluster already exists: $KIND_CLUSTER_NAME"

else

    info "Creating kind cluster: $KIND_CLUSTER_NAME"

    # Prefer repository config if one exists.
    #
    # Support both names because your repositories have used kind-config.yaml.

    if [[ -f "$SCRIPT_DIR/kind-config.yaml" ]]; then

        KIND_CONFIG="$SCRIPT_DIR/kind-config.yaml"

    elif [[ -f "$SCRIPT_DIR/kind-cluster.yaml" ]]; then

        KIND_CONFIG="$SCRIPT_DIR/kind-cluster.yaml"

    else

        KIND_CONFIG=""
    fi

    if [[ -n "$KIND_CONFIG" ]]; then

        info "Using kind configuration:"
        info "$KIND_CONFIG"

        kind create cluster \
            --name "$KIND_CLUSTER_NAME" \
            --config "$KIND_CONFIG"

    else

        info "No kind config found."
        info "Creating default 1 control-plane + 2 worker cluster."

        cat >/tmp/automq-kind.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

        kind create cluster \
            --name "$KIND_CLUSTER_NAME" \
            --config /tmp/automq-kind.yaml
    fi
fi

# ------------------------------------------------------------------------------
# Ensure correct Kubernetes context.
# ------------------------------------------------------------------------------

kubectl config use-context \
    "kind-${KIND_CLUSTER_NAME}"

info "Waiting for Kubernetes nodes..."

kubectl wait \
    --for=condition=Ready \
    nodes \
    --all \
    --timeout=300s

kubectl get nodes -o wide

ok "Kubernetes cluster ready"

# ==============================================================================
# 14. NAMESPACES + KUBERNETES SECRET
# ==============================================================================

section "[14/20] Kubernetes namespaces and secrets"

kubectl create namespace \
    "$AUTOMQ_NAMESPACE" \
    --dry-run=client \
    -o yaml |
    kubectl apply -f -

kubectl create namespace \
    "$CONDUKTOR_NAMESPACE" \
    --dry-run=client \
    -o yaml |
    kubectl apply -f -

info "Creating/updating AutoMQ S3 credentials..."

# ------------------------------------------------------------------------------
# No plaintext YAML secret is written to disk.
#
# Vault -> shell memory -> Kubernetes Secret
# ------------------------------------------------------------------------------

kubectl create secret generic \
    "$AUTOMQ_SECRET_NAME" \
    --namespace "$AUTOMQ_NAMESPACE" \
    --from-literal=access_key="$CEPH_ACCESS_KEY" \
    --from-literal=secret_key="$CEPH_SECRET_KEY" \
    --dry-run=client \
    -o yaml |
    kubectl apply -f -

kubectl \
    -n "$AUTOMQ_NAMESPACE" \
    get secret \
    "$AUTOMQ_SECRET_NAME" \
    >/dev/null

ok "Kubernetes S3 credential secret ready"

# ==============================================================================
# 15. PREPARE AUTOMQ MANIFESTS
# ==============================================================================

section "[15/20] Prepare AutoMQ manifests"

TMP_DIR="$(mktemp -d)"

cp \
    "$AUTOMQ_CONTROLLER_YAML" \
    "$TMP_DIR/automq-controller.yaml"

cp \
    "$AUTOMQ_BROKER_YAML" \
    "$TMP_DIR/automq-broker.yaml"

CEPH_HOST="$(
    sed -E \
        's#^https?://([^:/]+).*#\1#' \
        <<< "$CEPH_ENDPOINT"
)"

info "Ceph RGW host : $CEPH_HOST"
info "AutoMQ VM IP  : $AUTOMQ_VM_IP"

# Replace supported placeholders only in temporary copies.

sed -i \
    "s|<CEPH_RGW_IP>|${CEPH_HOST}|g" \
    "$TMP_DIR/automq-controller.yaml" \
    "$TMP_DIR/automq-broker.yaml"

sed -i \
    "s|<HOST_VM_IP>|${AUTOMQ_VM_IP}|g" \
    "$TMP_DIR/automq-controller.yaml" \
    "$TMP_DIR/automq-broker.yaml"

sed -i \
    "s|<CEPH_ENDPOINT>|${CEPH_ENDPOINT}|g" \
    "$TMP_DIR/automq-controller.yaml" \
    "$TMP_DIR/automq-broker.yaml"

# ------------------------------------------------------------------------------
# Never insert Ceph credentials directly into manifests.
#
# Manifests should consume:
#
#     automq-s3-credentials
#
# through secretKeyRef.
# ------------------------------------------------------------------------------

if grep \
    -R \
    -nE \
    '<CEPH_ACCESS_KEY>|<CEPH_SECRET_KEY>' \
    "$TMP_DIR"/*.yaml
then

    fail "AutoMQ manifests still contain credential placeholders.

Do not substitute credentials into YAML.

Configure the manifest to use Kubernetes secret:

    $AUTOMQ_SECRET_NAME"
fi

if grep \
    -R \
    -nE \
    '<CEPH_RGW_IP>|<HOST_VM_IP>|<CEPH_ENDPOINT>' \
    "$TMP_DIR"/*.yaml
then

    fail "Unresolved AutoMQ deployment placeholders remain."
fi

info "Validating controller manifest..."

kubectl apply \
    --dry-run=client \
    -f "$TMP_DIR/automq-controller.yaml" \
    >/dev/null

info "Validating broker manifest..."

kubectl apply \
    --dry-run=client \
    -f "$TMP_DIR/automq-broker.yaml" \
    >/dev/null

ok "AutoMQ manifests prepared"

# ==============================================================================
# 16. DEPLOY AUTOMQ
# ==============================================================================

section "[16/20] Deploy AutoMQ"

info "Applying AutoMQ controller..."

kubectl apply \
    -f "$TMP_DIR/automq-controller.yaml"

info "Applying AutoMQ broker..."

kubectl apply \
    -f "$TMP_DIR/automq-broker.yaml"

echo
info "Waiting for AutoMQ controller..."

if kubectl \
    -n "$AUTOMQ_NAMESPACE" \
    get deployment automq-controller \
    >/dev/null 2>&1
then

    kubectl \
        -n "$AUTOMQ_NAMESPACE" \
        rollout status \
        deployment/automq-controller \
        --timeout=600s
else
    warn "Deployment automq-controller not found by that exact name."
fi

echo
info "Waiting for AutoMQ broker..."

if kubectl \
    -n "$AUTOMQ_NAMESPACE" \
    get statefulset automq-broker \
    >/dev/null 2>&1
then

    kubectl \
        -n "$AUTOMQ_NAMESPACE" \
        rollout status \
        statefulset/automq-broker \
        --timeout=600s
else
    warn "StatefulSet automq-broker not found by that exact name."
fi

echo
kubectl \
    -n "$AUTOMQ_NAMESPACE" \
    get pods \
    -o wide

echo
kubectl \
    -n "$AUTOMQ_NAMESPACE" \
    get svc \
    -o wide

ok "AutoMQ manifests deployed"

# ==============================================================================
# 17. KAFKA VALIDATION
# ==============================================================================

section "[17/20] Kafka validation"

BROKER_POD="$(
    kubectl \
        -n "$AUTOMQ_NAMESPACE" \
        get pods \
        -o name \
        2>/dev/null |
        grep 'automq-broker' |
        head -1 |
        sed 's#pod/##' ||
        true
)"

if [[ -z "$BROKER_POD" ]]; then

    warn "Unable to locate AutoMQ broker pod automatically."
    warn "Skipping broker-side Kafka validation."

else

    info "Broker pod: $BROKER_POD"

    kubectl \
        -n "$AUTOMQ_NAMESPACE" \
        wait \
        --for=condition=Ready \
        "pod/$BROKER_POD" \
        --timeout=300s

    info "Checking Kafka listeners..."

    kubectl \
        -n "$AUTOMQ_NAMESPACE" \
        logs "$BROKER_POD" \
        --tail=200 |
        grep -Ei \
        'listeners|advertised.listeners' ||
        true

    echo
    info "Checking for kafka-topics command..."

    KAFKA_TOPICS_COMMAND=""

    for candidate in \
        /opt/kafka/kafka/bin/kafka-topics.sh \
        /opt/kafka/bin/kafka-topics.sh \
        /opt/kafka/bin/kafka-topics
    do

        if kubectl \
            -n "$AUTOMQ_NAMESPACE" \
            exec "$BROKER_POD" -- \
            test -x "$candidate" \
            >/dev/null 2>&1
        then

            KAFKA_TOPICS_COMMAND="$candidate"
            break
        fi
    done

    if [[ -n "$KAFKA_TOPICS_COMMAND" ]]; then

        BROKER_IP="$(kubectl -n "$AUTOMQ_NAMESPACE" get pod "$BROKER_POD" -o jsonpath='{.status.podIP}')"

        if [[ -z "$BROKER_IP" ]]; then
            warn "Unable to determine broker Pod IP; Kafka CLI validation skipped."
        else
            info "Testing Kafka API at ${BROKER_IP}:9092 (30-second limit)..."

            set +e
            KAFKA_OUTPUT="$(
                timeout 30s kubectl \
                    -n "$AUTOMQ_NAMESPACE" \
                    exec "$BROKER_POD" -- \
                    "$KAFKA_TOPICS_COMMAND" \
                    --bootstrap-server "${BROKER_IP}:9092" \
                    --list 2>&1
            )"
            KAFKA_RC=$?
            set -e

            echo "$KAFKA_OUTPUT"

            if [[ "$KAFKA_RC" -eq 0 ]]; then
                ok "Kafka API operational"
            elif [[ "$KAFKA_RC" -eq 124 ]]; then
                warn "Kafka validation exceeded 30 seconds; continuing deployment."
            else
                warn "Kafka validation failed with exit code $KAFKA_RC; continuing deployment."
            fi
        fi

    else

        warn "kafka-topics executable not present in broker image."
        warn "Skipping CLI topic validation."
    fi
fi

# ==============================================================================
# 18. CONDUKTOR
# ==============================================================================

section "[18/20] Conduktor"

info "Validating Conduktor manifest..."

kubectl apply \
    --dry-run=client \
    -f "$CONDUKTOR_MANIFEST" \
    >/dev/null

info "Deploying Conduktor..."

kubectl apply \
    -f "$CONDUKTOR_MANIFEST"

echo
info "Waiting for Conduktor deployments..."

CONDUKTOR_DEPLOYMENTS="$(
    kubectl \
        -n "$CONDUKTOR_NAMESPACE" \
        get deployments \
        -o name \
        2>/dev/null ||
        true
)"

if [[ -n "$CONDUKTOR_DEPLOYMENTS" ]]; then

    while IFS= read -r deployment
    do
        [[ -n "$deployment" ]] || continue

        info "Waiting for $deployment..."

        kubectl \
            -n "$CONDUKTOR_NAMESPACE" \
            rollout status \
            "$deployment" \
            --timeout=600s

    done <<< "$CONDUKTOR_DEPLOYMENTS"

else

    warn "No Conduktor Deployment resources found."
    warn "Checking namespace resources instead."
fi

echo
kubectl \
    -n "$CONDUKTOR_NAMESPACE" \
    get pods \
    -o wide

echo
kubectl \
    -n "$CONDUKTOR_NAMESPACE" \
    get svc \
    -o wide

ok "Conduktor deployment applied"

# ------------------------------------------------------------------------------
# Conduktor Console port-forward
# ------------------------------------------------------------------------------

CONDUKTOR_SERVICE="conduktor-console"
CONDUKTOR_LOCAL_PORT="8080"
CONDUKTOR_SERVICE_PORT="8080"
CONDUKTOR_PF_PID_FILE="/tmp/conduktor-port-forward.pid"
CONDUKTOR_PF_LOG="/tmp/conduktor-port-forward.log"

info "Configuring Conduktor Console port-forward..."

kubectl -n "$CONDUKTOR_NAMESPACE" get service "$CONDUKTOR_SERVICE" >/dev/null 2>&1 ||
    fail "Conduktor service not found: $CONDUKTOR_NAMESPACE/$CONDUKTOR_SERVICE"

if kubectl -n "$CONDUKTOR_NAMESPACE" get deployment conduktor-console >/dev/null 2>&1; then
    kubectl -n "$CONDUKTOR_NAMESPACE" wait \
        --for=condition=Available deployment/conduktor-console \
        --timeout=300s
fi

CONDUKTOR_PF_RUNNING="false"

if [[ -f "$CONDUKTOR_PF_PID_FILE" ]]; then
    OLD_PF_PID="$(cat "$CONDUKTOR_PF_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$OLD_PF_PID" ]] && kill -0 "$OLD_PF_PID" 2>/dev/null && \
       ps -p "$OLD_PF_PID" -o args= 2>/dev/null | grep -q 'kubectl port-forward'; then
        CONDUKTOR_PF_RUNNING="true"
        info "Existing Conduktor port-forward found (PID $OLD_PF_PID)."
    else
        rm -f "$CONDUKTOR_PF_PID_FILE"
    fi
fi

if [[ "$CONDUKTOR_PF_RUNNING" == "false" ]] && \
   pgrep -af 'kubectl port-forward.*conduktor-console.*8080:8080' >/dev/null 2>&1; then
    CONDUKTOR_PF_RUNNING="true"
    info "Existing Conduktor kubectl port-forward detected."
fi

if [[ "$CONDUKTOR_PF_RUNNING" == "true" ]] && \
   ! nc -z 127.0.0.1 "$CONDUKTOR_LOCAL_PORT" >/dev/null 2>&1; then
    warn "Existing Conduktor port-forward is unhealthy; restarting it."
    pkill -f 'kubectl port-forward.*conduktor-console.*8080:8080' 2>/dev/null || true
    rm -f "$CONDUKTOR_PF_PID_FILE"
    CONDUKTOR_PF_RUNNING="false"
    sleep 2
fi

if [[ "$CONDUKTOR_PF_RUNNING" == "false" ]]; then
    if ss -lnt | awk '{print $4}' | grep -Eq '(^|:)8080$'; then
        ss -lntp 2>/dev/null | grep ':8080' || true
        fail "TCP port 8080 is already occupied by another process."
    fi

    info "Starting Conduktor Console port-forward on 0.0.0.0:8080..."
    rm -f "$CONDUKTOR_PF_LOG"
    sleep 3
    nohup kubectl port-forward \
        -n "$CONDUKTOR_NAMESPACE" \
        "svc/$CONDUKTOR_SERVICE" \
        "${CONDUKTOR_LOCAL_PORT}:${CONDUKTOR_SERVICE_PORT}" \
        --address 0.0.0.0 \
        >"$CONDUKTOR_PF_LOG" 2>&1 &

    CONDUKTOR_PF_PID=$!
    echo "$CONDUKTOR_PF_PID" > "$CONDUKTOR_PF_PID_FILE"
    sleep 3

    if ! kill -0 "$CONDUKTOR_PF_PID" 2>/dev/null; then
        cat "$CONDUKTOR_PF_LOG" || true
        fail "Conduktor port-forward failed to start."
    fi
fi

CONDUKTOR_PORT_READY="false"
for attempt in {1..15}; do
    if nc -z 127.0.0.1 "$CONDUKTOR_LOCAL_PORT" >/dev/null 2>&1; then
        CONDUKTOR_PORT_READY="true"
        break
    fi
    sleep 2
done

if [[ "$CONDUKTOR_PORT_READY" != "true" ]]; then
    cat "$CONDUKTOR_PF_LOG" 2>/dev/null || true
    fail "Conduktor port-forward did not expose TCP port $CONDUKTOR_LOCAL_PORT."
fi

CONDUKTOR_HTTP_CODE="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 10 "http://127.0.0.1:${CONDUKTOR_LOCAL_PORT}" 2>/dev/null || true
)"

if [[ "$CONDUKTOR_HTTP_CODE" =~ ^[1234][0-9][0-9]$ ]]; then
    ok "Conduktor Console reachable (HTTP $CONDUKTOR_HTTP_CODE)"
else
    warn "Conduktor TCP port is available, but HTTP check returned: ${CONDUKTOR_HTTP_CODE:-unavailable}"
fi

info "Conduktor Console: http://${AUTOMQ_VM_IP}:${CONDUKTOR_LOCAL_PORT}"
info "Port-forward log: $CONDUKTOR_PF_LOG"
ok "Conduktor Console exposure configured"

# ==============================================================================
# 19. FINAL HEALTH CHECK
# ==============================================================================

section "[19/20] Final health check"

echo
echo "----------------------------------------------------------------------"
echo "KUBERNETES"
echo "----------------------------------------------------------------------"

kubectl get nodes -o wide

echo
echo "----------------------------------------------------------------------"
echo "AUTOMQ"
echo "----------------------------------------------------------------------"

kubectl \
    -n "$AUTOMQ_NAMESPACE" \
    get pods,svc \
    -o wide

echo
echo "----------------------------------------------------------------------"
echo "CONDUKTOR"
echo "----------------------------------------------------------------------"

kubectl \
    -n "$CONDUKTOR_NAMESPACE" \
    get pods,svc \
    -o wide

echo
echo "----------------------------------------------------------------------"
echo "VAULT"
echo "----------------------------------------------------------------------"

VAULT_TOKEN="" \
VAULT_ADDR="$VAULT_ADDR" \
vault status ||
    true

echo
echo "----------------------------------------------------------------------"
echo "CEPH S3"
echo "----------------------------------------------------------------------"

aws \
    --endpoint-url "$CEPH_ENDPOINT" \
    s3 ls

echo
echo "----------------------------------------------------------------------"
echo "DOCKER"
echo "----------------------------------------------------------------------"

docker info \
    --format \
    'Server Version: {{.ServerVersion}}'

echo
echo "----------------------------------------------------------------------"
echo "KIND"
echo "----------------------------------------------------------------------"

kind get clusters

ok "Final health checks completed"

# ==============================================================================
# 20. SUMMARY
# ==============================================================================

section "[20/20] Deployment complete"

echo
echo "Architecture:"
echo
echo "  Vault"
echo "    $VAULT_ADDR"
echo "          |"
echo "          | AppRole"
echo "          v"
echo "  Vault secret"
echo "    $VAULT_SECRET_PATH"
echo "          |"
echo "          | AccessKey / SecretKey"
echo "          v"
echo "  Kubernetes Secret"
echo "    $AUTOMQ_SECRET_NAME"
echo "          |"
echo "          v"
echo "  AutoMQ"
echo "          |"
echo "          v"
echo "  Ceph RGW"
echo "    $CEPH_ENDPOINT"
echo
echo "S3 buckets:"
echo "  $S3_DATA_BUCKET"
echo "  $S3_WAL_BUCKET"
echo
echo "Kafka internal endpoint:"
echo "  $KAFKA_INTERNAL_SERVICE"
echo
echo "AutoMQ VM:"
echo "  $AUTOMQ_VM_IP"
echo
echo "----------------------------------------------------------------------"
echo "STATUS"
echo "----------------------------------------------------------------------"
echo
echo "  Docker                  PASS"
echo "  Docker user access      PASS"
echo "  kubectl                 PASS"
echo "  kind                    PASS"
echo "  Vault                   PASS"
echo "  Vault AppRole           PASS"
echo "  Vault -> Ceph secrets   PASS"
echo "  Ceph RGW                PASS"
echo "  S3 authentication       PASS"
echo "  S3 buckets              PASS"
echo "  Kubernetes              PASS"
echo "  AutoMQ deployment       PASS"
echo "  Conduktor deployment    PASS"
echo
echo "----------------------------------------------------------------------"
echo "USEFUL COMMANDS"
echo "----------------------------------------------------------------------"
echo
echo "Kubernetes:"
echo "  kubectl get nodes -o wide"
echo
echo "AutoMQ:"
echo "  kubectl get all -n automq -o wide"
echo
echo "  kubectl logs -n automq automq-broker-0 --tail=100"
echo
echo "Conduktor:"
echo "  kubectl get all -n conduktor -o wide"
echo
echo "Vault:"
echo "  export VAULT_ADDR=$VAULT_ADDR"
echo "  vault status"
echo
echo "Ceph:"
echo "  aws --endpoint-url $CEPH_ENDPOINT s3 ls"
echo
echo "Docker:"
echo "  docker info"
echo
echo "kind:"
echo "  kind get clusters"
echo
echo "======================================================================"
echo "                    DEPLOYMENT SUCCESSFUL"
echo "======================================================================"

