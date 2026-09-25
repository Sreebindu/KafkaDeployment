#!/usr/bin/env bash

# ==============================================================================
# AutoMQ Deployment Prerequisites
#
# AutoMQ VM : 192.168.10.70
# Ceph VM   : 192.168.10.71
#
# Run BEFORE:
#
#   bash bootstrap-vault.sh
#   bash deploy-automq.sh
#
# Responsibilities:
#
#   - Install base dependencies
#   - Install AWS CLI if missing
#   - Install Vault if missing
#   - Configure a brand-new Vault for local Raft storage
#   - Start/enable Vault
#   - Detect Vault initialization state
#   - Initialize Vault ONLY with explicit confirmation
#   - Detect sealed Vault and request unseal key interactively
#   - Create dedicated AutoMQ -> Ceph SSH key
#   - Help install SSH public key on Ceph
#   - Verify passwordless SSH
#   - Verify remote access to the Rook S3 Secret
#   - Verify Ceph RGW connectivity
#   - Verify repository scripts/manifests
#
# SECURITY:
#
#   This script NEVER stores:
#
#       Vault root token
#       Vault unseal key
#       Ceph AccessKey
#       Ceph SecretKey
#
# ==============================================================================

set -Eeuo pipefail
umask 077

# ==============================================================================
# CONFIGURATION
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTOMQ_VM_IP="192.168.10.70"

CEPH_VM_IP="192.168.10.71"
CEPH_SSH_USER="rook-ceph"
CEPH_SSH_KEY="${HOME}/.ssh/automq-ceph"

CEPH_EXTERNAL_ENDPOINT="http://192.168.10.71:7480"

ROOK_NAMESPACE="rook-ceph"
ROOK_S3_SECRET="rook-ceph-object-user-rgw-store-s3-user"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_CONFIG="/etc/vault.d/vault.hcl"
VAULT_DATA_DIR="/opt/vault/data"

BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap-vault.sh"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-automq.sh"

AUTOMQ_CONTROLLER_YAML="$SCRIPT_DIR/automq-controller.yaml"
AUTOMQ_BROKER_YAML="$SCRIPT_DIR/automq-broker.yaml"
CONDUKTOR_YAML="$SCRIPT_DIR/conduktor.yaml"

export VAULT_ADDR

# ==============================================================================
# OUTPUT FUNCTIONS
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

# ==============================================================================
# CLEANUP
# ==============================================================================

cleanup()
{
    unset VAULT_INIT_OUTPUT 2>/dev/null || true
    unset VAULT_UNSEAL_KEY 2>/dev/null || true
    unset VAULT_STATUS_JSON 2>/dev/null || true
    unset ROOK_SECRET_KEYS 2>/dev/null || true
}

trap cleanup EXIT

# ==============================================================================
# 1. PRE-FLIGHT
# ==============================================================================

section "[1/12] Pre-flight"

info "Repository       : $SCRIPT_DIR"
info "AutoMQ VM        : $AUTOMQ_VM_IP"
info "Ceph VM          : ${CEPH_SSH_USER}@${CEPH_VM_IP}"
info "Ceph RGW         : $CEPH_EXTERNAL_ENDPOINT"
info "Rook namespace   : $ROOK_NAMESPACE"
info "Rook S3 Secret   : $ROOK_S3_SECRET"
info "Vault            : $VAULT_ADDR"

if [[ "$EUID" -eq 0 ]]; then
    fail "Do not run this entire script as root.

Run it as your normal AutoMQ user:

    bash preflight-automq.sh

The script uses sudo only where required."
fi

command_exists sudo ||
    fail "sudo is required."

sudo -v ||
    fail "sudo authentication failed."

ok "Pre-flight complete"

# ==============================================================================
# 2. BASE DEPENDENCIES
# ==============================================================================

section "[2/12] Base dependencies"

PACKAGES=(
    curl
    wget
    jq
    unzip
    ca-certificates
    gnupg
    lsb-release
    netcat-openbsd
    socat
    openssl
    openssh-client
)

MISSING_PACKAGES=()

for package in "${PACKAGES[@]}"; do

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

for cmd in \
    curl \
    wget \
    jq \
    unzip \
    openssl \
    ssh \
    ssh-keygen
do

    command_exists "$cmd" ||
        fail "Required command is unavailable after package installation: $cmd"

done

ok "Base dependencies ready"

# ==============================================================================
# 3. AWS CLI
# ==============================================================================

section "[3/12] AWS CLI"

if command_exists aws; then

    info "AWS CLI already installed."

else

    info "Installing AWS CLI v2..."

    rm -rf \
        /tmp/aws \
        /tmp/awscliv2.zip

    curl \
        --fail \
        --location \
        --output /tmp/awscliv2.zip \
        "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"

    unzip \
        -q \
        /tmp/awscliv2.zip \
        -d /tmp

    sudo /tmp/aws/install

fi

aws --version

ok "AWS CLI ready"

# ==============================================================================
# 4. CEPH SSH KEY
# ==============================================================================

section "[4/12] AutoMQ -> Ceph SSH key"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ -f "$CEPH_SSH_KEY" ]]; then

    info "Dedicated Ceph SSH key already exists:"
    info "$CEPH_SSH_KEY"

else

    info "Creating dedicated AutoMQ -> Ceph SSH key..."

    ssh-keygen \
        -t ed25519 \
        -f "$CEPH_SSH_KEY" \
        -C "automq-to-ceph" \
        -N ""

    ok "SSH key generated"

fi

[[ -f "$CEPH_SSH_KEY" ]] ||
    fail "SSH private key is missing."

[[ -f "${CEPH_SSH_KEY}.pub" ]] ||
    fail "SSH public key is missing."

chmod 600 "$CEPH_SSH_KEY"
chmod 644 "${CEPH_SSH_KEY}.pub"

# ------------------------------------------------------------------------------
# Test whether key authentication already works.
# ------------------------------------------------------------------------------

if ssh \
    -i "$CEPH_SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
    'true' \
    >/dev/null 2>&1
then

    ok "Passwordless SSH already configured"

else

    echo
    info "The SSH public key has not yet been authorized on the Ceph VM."
    echo
    info "The following command will ask for the '${CEPH_SSH_USER}' password once."
    echo

    ssh-copy-id \
        -i "${CEPH_SSH_KEY}.pub" \
        "${CEPH_SSH_USER}@${CEPH_VM_IP}"

fi

# ------------------------------------------------------------------------------
# Final SSH verification.
# ------------------------------------------------------------------------------

info "Testing passwordless SSH..."

CEPH_HOSTNAME="$(
    ssh \
        -i "$CEPH_SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
        'hostname'
)"

[[ -n "$CEPH_HOSTNAME" ]] ||
    fail "Passwordless SSH to Ceph failed."

info "Remote hostname: $CEPH_HOSTNAME"

ok "AutoMQ -> Ceph SSH ready"

# ==============================================================================
# 5. ROOK SECRET ACCESS
# ==============================================================================

section "[5/12] Rook S3 Secret access"

info "Checking remote kubectl..."

ssh \
    -i "$CEPH_SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
    'command -v kubectl >/dev/null' ||
    fail "kubectl is not available for the Ceph SSH user."

info "Checking Rook S3 Secret..."

if ! ssh \
    -i "$CEPH_SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
    "kubectl get secret \
        -n '$ROOK_NAMESPACE' \
        '$ROOK_S3_SECRET' \
        >/dev/null"
then

    fail "Unable to read the Rook S3 Secret:

Namespace:
    $ROOK_NAMESPACE

Secret:
    $ROOK_S3_SECRET"
fi

ROOK_SECRET_KEYS="$(
    ssh \
        -i "$CEPH_SSH_KEY" \
        -o BatchMode=yes \
        "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
        "kubectl get secret \
            -n '$ROOK_NAMESPACE' \
            '$ROOK_S3_SECRET' \
            -o json" |
    jq -r '.data | keys[]'
)"

for required_key in \
    AccessKey \
    SecretKey \
    Endpoint
do

    if ! grep -Fxq "$required_key" <<< "$ROOK_SECRET_KEYS"; then

        fail "Rook Secret does not contain required field:

$required_key"

    fi

done

info "Rook Secret fields:"
echo "$ROOK_SECRET_KEYS"

ok "Rook S3 Secret accessible"

unset ROOK_SECRET_KEYS

# ==============================================================================
# 6. CEPH RGW CONNECTIVITY
# ==============================================================================

section "[6/12] Ceph RGW connectivity"

info "Testing TCP port 7480..."

nc -z \
    -w 5 \
    "$CEPH_VM_IP" \
    7480 ||
    fail "Cannot connect to Ceph RGW:

${CEPH_VM_IP}:7480"

ok "Ceph RGW TCP port reachable"

info "Testing HTTP endpoint..."

if ! curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 10 \
    "$CEPH_EXTERNAL_ENDPOINT" \
    >/dev/null
then

    fail "Ceph RGW HTTP endpoint is not reachable:

$CEPH_EXTERNAL_ENDPOINT"
fi

ok "Ceph RGW reachable"

# ==============================================================================
# 7. VAULT INSTALLATION
# ==============================================================================

section "[7/12] Vault installation"

VAULT_WAS_INSTALLED="true"

if command_exists vault; then

    info "Vault already installed."

    vault version

else

    VAULT_WAS_INSTALLED="false"

    info "Vault is not installed."
    info "Installing HashiCorp Vault..."

    sudo install \
        -m 0755 \
        -d \
        /etc/apt/keyrings

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        "https://apt.releases.hashicorp.com/gpg" |
        gpg --dearmor |
        sudo tee \
            /etc/apt/keyrings/hashicorp-archive-keyring.gpg \
            >/dev/null

    sudo chmod \
        a+r \
        /etc/apt/keyrings/hashicorp-archive-keyring.gpg

    CODENAME="$(
        . /etc/os-release
        echo "$VERSION_CODENAME"
    )"

    echo \
"deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" |
        sudo tee \
            /etc/apt/sources.list.d/hashicorp.list \
            >/dev/null

    sudo apt-get update

    sudo apt-get install -y vault

    vault version

fi

command_exists vault ||
    fail "Vault installation failed."

ok "Vault installed"

# ==============================================================================
# 8. VAULT CONFIGURATION
# ==============================================================================

section "[8/12] Vault configuration"

# ------------------------------------------------------------------------------
# IMPORTANT:
#
# Existing Vault configuration is not overwritten.
#
# We create our Raft configuration only when Vault was newly installed and
# there is no usable existing configuration.
# ------------------------------------------------------------------------------

if [[ "$VAULT_WAS_INSTALLED" == "false" ]]; then

    info "Preparing new Vault Raft storage..."

    sudo install \
        -d \
        -o vault \
        -g vault \
        -m 0700 \
        "$VAULT_DATA_DIR"

    if sudo test -s "$VAULT_CONFIG"; then

        info "Vault package supplied an existing configuration."
        info "Preserving:"
        info "$VAULT_CONFIG"

    else

        info "Creating Vault configuration:"
        info "$VAULT_CONFIG"

        sudo tee "$VAULT_CONFIG" >/dev/null <<'EOF'
ui = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "automq-vault-1"
}

listener "tcp" {
  address         = "127.0.0.1:8200"
  cluster_address = "127.0.0.1:8201"
  tls_disable     = 1
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

disable_mlock = true
EOF

        sudo chown \
            root:vault \
            "$VAULT_CONFIG"

        sudo chmod \
            0640 \
            "$VAULT_CONFIG"

    fi

else

    info "Existing Vault installation detected."
    info "Vault configuration will not be modified."

fi

sudo systemctl enable vault >/dev/null

if ! systemctl is-active --quiet vault; then

    info "Starting Vault..."

    sudo systemctl start vault

    sleep 3

fi

if ! systemctl is-active --quiet vault; then

    echo
    sudo systemctl status vault --no-pager || true
    echo
    sudo journalctl \
        -u vault \
        --no-pager \
        -n 100 || true

    fail "Vault failed to start."
fi

ok "Vault service running"

# ==============================================================================
# 9. VAULT STATE / INITIALIZATION
# ==============================================================================

section "[9/12] Vault initialization state"

export VAULT_ADDR

VAULT_STATUS_JSON="$(
    vault status \
        -format=json \
        2>/dev/null ||
        true
)"

[[ -n "$VAULT_STATUS_JSON" ]] ||
    fail "Unable to communicate with Vault:

$VAULT_ADDR"

jq -e . >/dev/null 2>&1 <<< "$VAULT_STATUS_JSON" ||
    fail "Vault returned invalid status JSON."

VAULT_INITIALIZED="$(
    jq -r '.initialized' <<< "$VAULT_STATUS_JSON"
)"

VAULT_SEALED="$(
    jq -r '.sealed' <<< "$VAULT_STATUS_JSON"
)"

VAULT_STORAGE="$(
    jq -r '.storage_type // "unknown"' <<< "$VAULT_STATUS_JSON"
)"

echo
echo "Initialized : $VAULT_INITIALIZED"
echo "Sealed      : $VAULT_SEALED"
echo "Storage     : $VAULT_STORAGE"
echo

# ------------------------------------------------------------------------------
# Never initialize an already initialized Vault.
# ------------------------------------------------------------------------------

if [[ "$VAULT_INITIALIZED" == "false" ]]; then

    echo "----------------------------------------------------------------------"
    echo "NEW VAULT DETECTED"
    echo "----------------------------------------------------------------------"
    echo
    echo "Vault has NOT been initialized."
    echo
    echo "Initialization will create:"
    echo
    echo "  - one Vault unseal key"
    echo "  - one initial Vault root token"
    echo
    echo "YOU MUST securely save both values outside this repository."
    echo
    echo "Losing the unseal key can make the Vault data inaccessible."
    echo

    read -r -p \
        "Initialize this NEW Vault now? Type YES to continue: " \
        INITIALIZE_CONFIRMATION

    if [[ "$INITIALIZE_CONFIRMATION" != "YES" ]]; then

        echo
        warn "Vault initialization cancelled."
        echo
        echo "Initialize Vault manually when ready:"
        echo
        echo "    export VAULT_ADDR=$VAULT_ADDR"
        echo "    vault operator init -key-shares=1 -key-threshold=1"
        echo

        exit 20
    fi

    echo
    echo "======================================================================"
    echo "IMPORTANT"
    echo "======================================================================"
    echo
    echo "The next output contains sensitive Vault recovery credentials."
    echo
    echo "Store them securely OUTSIDE:"
    echo
    echo "    $SCRIPT_DIR"
    echo
    echo "Do NOT commit them to Git."
    echo
    echo "======================================================================"
    echo

    # Intentionally print directly to the terminal.
    #
    # Do NOT capture this output into a shell variable or write it to disk.

    vault operator init \
        -key-shares=1 \
        -key-threshold=1

    echo
    echo "======================================================================"
    echo
    echo "Vault initialization completed."
    echo
    echo "Confirm that you securely saved BOTH:"
    echo
    echo "  1. Unseal Key"
    echo "  2. Initial Root Token"
    echo

    read -r -p \
        "Type SAVED after securely storing them: " \
        SAVE_CONFIRMATION

    [[ "$SAVE_CONFIRMATION" == "SAVED" ]] ||
        fail "Stopping so Vault credentials are not accidentally lost."

    VAULT_INITIALIZED="true"
    VAULT_SEALED="true"

else

    ok "Vault already initialized"

fi

# ==============================================================================
# 10. VAULT UNSEAL
# ==============================================================================

section "[10/12] Vault seal state"

VAULT_STATUS_JSON="$(
    vault status \
        -format=json \
        2>/dev/null ||
        true
)"

VAULT_SEALED="$(
    jq -r '.sealed' <<< "$VAULT_STATUS_JSON"
)"

if [[ "$VAULT_SEALED" == "true" ]]; then

    warn "Vault is sealed."
    echo
    echo "The unseal key will be requested interactively."
    echo
    echo "It will NOT be written to disk."
    echo

    # Vault itself prompts securely for the key.
    vault operator unseal

fi

VAULT_STATUS_JSON="$(
    vault status \
        -format=json \
        2>/dev/null ||
        true
)"

VAULT_INITIALIZED="$(
    jq -r '.initialized' <<< "$VAULT_STATUS_JSON"
)"

VAULT_SEALED="$(
    jq -r '.sealed' <<< "$VAULT_STATUS_JSON"
)"

echo
echo "Initialized : $VAULT_INITIALIZED"
echo "Sealed      : $VAULT_SEALED"

[[ "$VAULT_INITIALIZED" == "true" ]] ||
    fail "Vault is not initialized."

[[ "$VAULT_SEALED" == "false" ]] ||
    fail "Vault remains sealed."

ok "Vault initialized and unsealed"

# ==============================================================================
# 11. REPOSITORY VALIDATION
# ==============================================================================

section "[11/12] Repository validation"

REQUIRED_FILES=(
    "$BOOTSTRAP_SCRIPT"
    "$DEPLOY_SCRIPT"
    "$AUTOMQ_CONTROLLER_YAML"
    "$AUTOMQ_BROKER_YAML"
    "$CONDUKTOR_YAML"
)

for file in "${REQUIRED_FILES[@]}"; do

    if [[ ! -f "$file" ]]; then

        fail "Required repository file missing:

$file"

    fi

    info "Found: $(basename "$file")"

done

info "Checking bootstrap-vault.sh syntax..."

bash -n "$BOOTSTRAP_SCRIPT" ||
    fail "bootstrap-vault.sh contains a Bash syntax error."

ok "bootstrap-vault.sh syntax valid"

info "Checking deploy-automq.sh syntax..."

bash -n "$DEPLOY_SCRIPT" ||
    fail "deploy-automq.sh contains a Bash syntax error."

ok "deploy-automq.sh syntax valid"

# ==============================================================================
# 12. FINAL VALIDATION
# ==============================================================================

section "[12/12] Final prerequisite validation"

echo
echo "----------------------------------------------------------------------"
echo "VAULT"
echo "----------------------------------------------------------------------"
echo

vault status || true

echo
echo "----------------------------------------------------------------------"
echo "CEPH SSH"
echo "----------------------------------------------------------------------"
echo

ssh \
    -i "$CEPH_SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
    'hostname'

echo
echo "----------------------------------------------------------------------"
echo "CEPH RGW"
echo "----------------------------------------------------------------------"
echo

if nc -z \
    -w 5 \
    "$CEPH_VM_IP" \
    7480
then
    echo "${CEPH_VM_IP}:7480 reachable"
else
    fail "Ceph RGW port is no longer reachable."
fi

echo
echo "----------------------------------------------------------------------"
echo "ROOK S3 SECRET"
echo "----------------------------------------------------------------------"
echo

ssh \
    -i "$CEPH_SSH_KEY" \
    -o BatchMode=yes \
    "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
    "kubectl get secret \
        -n '$ROOK_NAMESPACE' \
        '$ROOK_S3_SECRET' \
        -o json" |
jq -r '.data | keys[]'

# ==============================================================================
# SUMMARY
# ==============================================================================

echo
echo "======================================================================"
echo "                 AUTOMQ PREREQUISITES COMPLETE"
echo "======================================================================"
echo
echo "AutoMQ VM:"
echo "  $AUTOMQ_VM_IP"
echo
echo "Ceph VM:"
echo "  ${CEPH_SSH_USER}@${CEPH_VM_IP}"
echo
echo "Ceph RGW:"
echo "  $CEPH_EXTERNAL_ENDPOINT"
echo
echo "Rook Secret:"
echo "  ${ROOK_NAMESPACE}/${ROOK_S3_SECRET}"
echo
echo "Vault:"
echo "  $VAULT_ADDR"
echo
echo "SSH key:"
echo "  $CEPH_SSH_KEY"
echo
echo "----------------------------------------------------------------------"
echo "STATUS"
echo "----------------------------------------------------------------------"
echo
echo "  Base dependencies       PASS"
echo "  AWS CLI                 PASS"
echo "  Ceph SSH key            PASS"
echo "  Passwordless Ceph SSH   PASS"
echo "  Rook Secret access      PASS"
echo "  Ceph RGW connectivity   PASS"
echo "  Vault installed         PASS"
echo "  Vault service           PASS"
echo "  Vault initialized       PASS"
echo "  Vault unsealed          PASS"
echo "  Repository files        PASS"
echo "  Script syntax           PASS"
echo
echo "======================================================================"
echo "NEXT STEP"
echo "======================================================================"
echo
echo "Run:"
echo
echo "    cd \"$SCRIPT_DIR\""
echo "    bash bootstrap-vault.sh"
echo
echo "After bootstrap-vault.sh succeeds:"
echo
echo "    bash deploy-automq.sh"
echo
echo "======================================================================"
