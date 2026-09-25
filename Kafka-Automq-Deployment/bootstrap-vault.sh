#!/usr/bin/env bash

# ==============================================================================
# AutoMQ Vault Bootstrap
#
# Flow:
#
#   AutoMQ VM
#       |
#       | SSH key authentication
#       v
#   Ceph VM / Rook Kubernetes
#       |
#       | Kubernetes Secret
#       v
#   AccessKey + SecretKey
#       |
#       v
#   Vault KV: automq/ceph
#       |
#       v
#   Vault AppRole: automq
#       |
#       +--> /etc/automq-vault/role-id
#       +--> /etc/automq-vault/secret-id
#
# IMPORTANT:
#
#   - Vault is treated as persistent infrastructure.
#   - Existing Vault storage is NEVER deleted.
#   - Existing Vault is NEVER reinitialized.
#   - Root token is NEVER stored by this script.
#   - Unseal key is NEVER stored by this script.
#   - Ceph credentials are retrieved automatically from Rook.
#
# ==============================================================================

set -Eeuo pipefail
umask 077

# ==============================================================================
# CONFIGURATION
# ==============================================================================

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

VAULT_KV_MOUNT="automq"
VAULT_SECRET_PATH="automq/ceph"

VAULT_POLICY_NAME="automq-policy"
VAULT_APPROLE_NAME="automq"

VAULT_ROLE_ID_FILE="/etc/automq-vault/role-id"
VAULT_SECRET_ID_FILE="/etc/automq-vault/secret-id"

# ------------------------------------------------------------------------------
# Ceph / Rook
# ------------------------------------------------------------------------------

CEPH_VM_IP="192.168.10.71"
CEPH_SSH_USER="rook-ceph"

CEPH_SSH_KEY="${HOME}/.ssh/automq-ceph"

ROOK_NAMESPACE="rook-ceph"

ROOK_S3_SECRET="rook-ceph-object-user-rgw-store-s3-user"

# Rook's Secret contains:
#
#   AccessKey
#   SecretKey
#   Endpoint
#
# However Endpoint is currently:
#
#   http://rook-ceph-rgw-rgw-store.rook-ceph.svc:80
#
# That address is internal to the Rook Kubernetes cluster and is not suitable
# for the separate AutoMQ kind cluster.
#
# Therefore AutoMQ uses the externally reachable RGW address below.

CEPH_EXTERNAL_ENDPOINT="http://192.168.10.71:7480"

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
    unset ROOT_TOKEN 2>/dev/null || true

    unset ROOK_SECRET_JSON 2>/dev/null || true

    unset CEPH_ACCESS_KEY 2>/dev/null || true
    unset CEPH_SECRET_KEY 2>/dev/null || true
    unset ROOK_ENDPOINT 2>/dev/null || true

    unset AWS_ACCESS_KEY_ID 2>/dev/null || true
    unset AWS_SECRET_ACCESS_KEY 2>/dev/null || true

    unset ROLE_ID 2>/dev/null || true
    unset SECRET_ID 2>/dev/null || true
    unset TEST_TOKEN 2>/dev/null || true

    if [[ -n "${POLICY_FILE:-}" ]]; then
        rm -f "$POLICY_FILE" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# ==============================================================================
# 1. PRE-FLIGHT
# ==============================================================================

section "[1/10] Pre-flight"

info "Vault             : $VAULT_ADDR"
info "Ceph VM           : ${CEPH_SSH_USER}@${CEPH_VM_IP}"
info "SSH key           : $CEPH_SSH_KEY"
info "Rook namespace    : $ROOK_NAMESPACE"
info "Rook S3 secret    : $ROOK_S3_SECRET"
info "External RGW      : $CEPH_EXTERNAL_ENDPOINT"

for cmd in \
    vault \
    ssh \
    jq \
    base64 \
    curl
do
    command_exists "$cmd" ||
        fail "Required command not installed: $cmd"
done

if ! command_exists aws; then
    fail "AWS CLI is required.

Install AWS CLI before running this bootstrap."
fi

[[ -f "$CEPH_SSH_KEY" ]] ||
    fail "Ceph SSH private key does not exist:

$CEPH_SSH_KEY

Create it first with:

    ssh-keygen -t ed25519 \
      -f ~/.ssh/automq-ceph \
      -C 'automq-to-ceph'"
    
chmod 600 "$CEPH_SSH_KEY"

ok "Pre-flight complete"

# ==============================================================================
# 2. CHECK VAULT SERVICE
# ==============================================================================

section "[2/10] Vault service"

if ! systemctl is-active --quiet vault; then

    info "Vault service is not running."
    info "Starting existing Vault service..."

    sudo systemctl start vault

    sleep 2
fi

systemctl is-active --quiet vault ||
    fail "Vault service failed to start."

ok "Vault service running"

# ==============================================================================
# 3. CHECK VAULT STATE
# ==============================================================================

section "[3/10] Vault state"

VAULT_STATUS_JSON="$(
    VAULT_ADDR="$VAULT_ADDR" \
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

echo "Initialized : $VAULT_INITIALIZED"
echo "Sealed      : $VAULT_SEALED"
echo "Storage     : $VAULT_STORAGE"

if [[ "$VAULT_INITIALIZED" != "true" ]]; then

    fail "Vault is not initialized.

This script intentionally does NOT automatically initialize Vault.

Initialize Vault once manually and securely preserve:

    - unseal key
    - initial root token

Then rerun this script."
fi

if [[ "$VAULT_SEALED" == "true" ]]; then

    echo
    echo "Vault is initialized but SEALED."
    echo
    echo "Unseal it:"
    echo
    echo "    export VAULT_ADDR=$VAULT_ADDR"
    echo "    vault operator unseal"
    echo
    echo "Then rerun:"
    echo
    echo "    bash bootstrap-vault.sh"
    echo

    exit 21
fi

[[ "$VAULT_SEALED" == "false" ]] ||
    fail "Unable to determine Vault seal state."

ok "Vault is initialized and unsealed"

# ==============================================================================
# 4. TEST CEPH SSH
# ==============================================================================

section "[4/10] Ceph SSH"

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
    fail "SSH connection to Ceph VM failed."

info "Remote hostname: $CEPH_HOSTNAME"

ok "Passwordless SSH operational"

# ==============================================================================
# 5. RETRIEVE RADOSGW CREDENTIALS
# ==============================================================================

section "[5/10] Retrieve Rook S3 credentials"

info "Reading Rook Kubernetes Secret..."

ROOK_SECRET_JSON="$(
    ssh \
        -i "$CEPH_SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "${CEPH_SSH_USER}@${CEPH_VM_IP}" \
        "kubectl get secret \
            -n '$ROOK_NAMESPACE' \
            '$ROOK_S3_SECRET' \
            -o json"
)"

[[ -n "$ROOK_SECRET_JSON" ]] ||
    fail "Rook returned an empty Kubernetes Secret."

jq -e . >/dev/null 2>&1 <<< "$ROOK_SECRET_JSON" ||
    fail "Rook Secret response is not valid JSON."

# ------------------------------------------------------------------------------
# Verify expected fields before decoding.
# ------------------------------------------------------------------------------

jq -e '.data.AccessKey' >/dev/null <<< "$ROOK_SECRET_JSON" ||
    fail "Rook Secret does not contain AccessKey."

jq -e '.data.SecretKey' >/dev/null <<< "$ROOK_SECRET_JSON" ||
    fail "Rook Secret does not contain SecretKey."

jq -e '.data.Endpoint' >/dev/null <<< "$ROOK_SECRET_JSON" ||
    fail "Rook Secret does not contain Endpoint."

# ------------------------------------------------------------------------------
# Decode credentials.
# ------------------------------------------------------------------------------

CEPH_ACCESS_KEY="$(
    jq -r '.data.AccessKey' <<< "$ROOK_SECRET_JSON" |
    base64 -d
)"

CEPH_SECRET_KEY="$(
    jq -r '.data.SecretKey' <<< "$ROOK_SECRET_JSON" |
    base64 -d
)"

ROOK_ENDPOINT="$(
    jq -r '.data.Endpoint' <<< "$ROOK_SECRET_JSON" |
    base64 -d
)"

[[ -n "$CEPH_ACCESS_KEY" ]] ||
    fail "Decoded Ceph AccessKey is empty."

[[ -n "$CEPH_SECRET_KEY" ]] ||
    fail "Decoded Ceph SecretKey is empty."

[[ -n "$ROOK_ENDPOINT" ]] ||
    fail "Decoded Rook Endpoint is empty."

info "AccessKey     : retrieved"
info "SecretKey     : retrieved"
info "Rook endpoint : $ROOK_ENDPOINT"

# ------------------------------------------------------------------------------
# Detect internal Kubernetes endpoint.
# ------------------------------------------------------------------------------

if [[ "$ROOK_ENDPOINT" == *".svc"* ]]; then

    warn "Rook endpoint is Kubernetes-internal:"
    warn "$ROOK_ENDPOINT"

    info "Using externally reachable RGW endpoint:"
    info "$CEPH_EXTERNAL_ENDPOINT"

    CEPH_ENDPOINT="$CEPH_EXTERNAL_ENDPOINT"

else

    info "Rook supplied a non-cluster-local endpoint."

    CEPH_ENDPOINT="$ROOK_ENDPOINT"
fi

ok "Ceph credentials retrieved"

# The raw Kubernetes Secret is no longer needed.

unset ROOK_SECRET_JSON

# ==============================================================================
# 6. VALIDATE CEPH S3
# ==============================================================================

section "[6/10] Validate Ceph S3"

info "Endpoint: $CEPH_ENDPOINT"

if ! curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time 10 \
    "$CEPH_ENDPOINT" \
    >/dev/null
then

    fail "Ceph RGW endpoint is not reachable:

$CEPH_ENDPOINT"
fi

export AWS_ACCESS_KEY_ID="$CEPH_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$CEPH_SECRET_KEY"
export AWS_DEFAULT_REGION="us-east-1"

info "Testing S3 authentication..."

if ! aws \
    --endpoint-url "$CEPH_ENDPOINT" \
    s3api list-buckets \
    >/dev/null
then

    fail "Ceph credentials were retrieved successfully,
but authentication against the external RGW endpoint failed.

Endpoint:

    $CEPH_ENDPOINT"
fi

ok "Ceph RGW authentication successful"

# ==============================================================================
# 7. VAULT ADMIN AUTHENTICATION
# ==============================================================================

section "[7/10] Vault administrator authentication"

# ------------------------------------------------------------------------------
# If the current shell already has a valid Vault token, use it.
#
# Otherwise request a token interactively.
#
# The token is NOT written to disk.
# ------------------------------------------------------------------------------

VAULT_ADMIN_READY="false"

if [[ -n "${VAULT_TOKEN:-}" ]]; then

    if VAULT_ADDR="$VAULT_ADDR" \
       vault token lookup \
       >/dev/null 2>&1
    then

        info "Using valid VAULT_TOKEN from current environment."

        VAULT_ADMIN_READY="true"
    fi
fi

if [[ "$VAULT_ADMIN_READY" != "true" ]]; then

    echo
    echo "Vault administrative authentication is required."
    echo
    echo "The token will NOT be saved by this script."
    echo

    read -r -s -p "Vault admin/root token: " ROOT_TOKEN
    echo

    [[ -n "$ROOT_TOKEN" ]] ||
        fail "No Vault token supplied."

    if ! VAULT_ADDR="$VAULT_ADDR" \
         VAULT_TOKEN="$ROOT_TOKEN" \
         vault token lookup \
         >/dev/null 2>&1
    then

        fail "Vault token authentication failed."
    fi

    export VAULT_TOKEN="$ROOT_TOKEN"

    unset ROOT_TOKEN
fi

ok "Vault administrative authentication successful"

# ==============================================================================
# 8. CONFIGURE VAULT
# ==============================================================================

section "[8/10] Configure Vault"

# ------------------------------------------------------------------------------
# KV v2 mount
# ------------------------------------------------------------------------------

if VAULT_ADDR="$VAULT_ADDR" \
   VAULT_TOKEN="$VAULT_TOKEN" \
   vault secrets list \
       -format=json |
   jq -e \
       --arg mount "${VAULT_KV_MOUNT}/" \
       'has($mount)' \
       >/dev/null
then

    info "KV mount already exists: ${VAULT_KV_MOUNT}/"

else

    info "Enabling KV v2 mount: ${VAULT_KV_MOUNT}/"

    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault secrets enable \
        -path="$VAULT_KV_MOUNT" \
        kv-v2
fi

# ------------------------------------------------------------------------------
# AppRole authentication
# ------------------------------------------------------------------------------

if VAULT_ADDR="$VAULT_ADDR" \
   VAULT_TOKEN="$VAULT_TOKEN" \
   vault auth list \
       -format=json |
   jq -e \
       'has("approle/")' \
       >/dev/null
then

    info "AppRole auth already enabled"

else

    info "Enabling AppRole authentication..."

    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault auth enable approle
fi

# ------------------------------------------------------------------------------
# Write/update Ceph credentials.
#
# This intentionally synchronizes Vault with the current Rook credentials.
# ------------------------------------------------------------------------------

info "Synchronizing Ceph credentials to Vault..."

VAULT_ADDR="$VAULT_ADDR" \
VAULT_TOKEN="$VAULT_TOKEN" \
vault kv put \
    "$VAULT_SECRET_PATH" \
    access_key="$CEPH_ACCESS_KEY" \
    secret_key="$CEPH_SECRET_KEY" \
    endpoint="$CEPH_ENDPOINT" \
    >/dev/null

ok "Vault secret synchronized: $VAULT_SECRET_PATH"

# ------------------------------------------------------------------------------
# Policy
# ------------------------------------------------------------------------------

POLICY_FILE="$(mktemp)"

cat >"$POLICY_FILE" <<EOF
path "${VAULT_KV_MOUNT}/data/ceph" {
  capabilities = ["read"]
}

path "${VAULT_KV_MOUNT}/metadata/ceph" {
  capabilities = ["read"]
}
EOF

info "Configuring Vault policy: $VAULT_POLICY_NAME"

VAULT_ADDR="$VAULT_ADDR" \
VAULT_TOKEN="$VAULT_TOKEN" \
vault policy write \
    "$VAULT_POLICY_NAME" \
    "$POLICY_FILE" \
    >/dev/null

ok "Policy configured"

# ------------------------------------------------------------------------------
# AppRole
# ------------------------------------------------------------------------------

info "Configuring AppRole: $VAULT_APPROLE_NAME"

VAULT_ADDR="$VAULT_ADDR" \
VAULT_TOKEN="$VAULT_TOKEN" \
vault write \
    "auth/approle/role/$VAULT_APPROLE_NAME" \
    token_policies="$VAULT_POLICY_NAME" \
    token_ttl="1h" \
    token_max_ttl="4h" \
    secret_id_num_uses=0 \
    secret_id_ttl=0 \
    >/dev/null

ok "AppRole configured"

# ==============================================================================
# 9. APPROLE CREDENTIAL FILES
# ==============================================================================

section "[9/10] AppRole credentials"

ROLE_ID="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$VAULT_TOKEN" \
    vault read \
        -field=role_id \
        "auth/approle/role/$VAULT_APPROLE_NAME/role-id"
)"

[[ -n "$ROLE_ID" ]] ||
    fail "Unable to retrieve AppRole RoleID."

# ------------------------------------------------------------------------------
# Preserve existing SecretID if it is still valid.
#
# We don't rotate the SecretID unnecessarily on every bootstrap.
# ------------------------------------------------------------------------------

SECRET_ID=""

if sudo test -s "$VAULT_SECRET_ID_FILE"; then

    info "Testing existing SecretID..."

    EXISTING_SECRET_ID="$(
        sudo cat "$VAULT_SECRET_ID_FILE"
    )"

    if [[ -n "$EXISTING_SECRET_ID" ]]; then

        TEST_TOKEN="$(
            VAULT_ADDR="$VAULT_ADDR" \
            vault write \
                -field=token \
                auth/approle/login \
                role_id="$ROLE_ID" \
                secret_id="$EXISTING_SECRET_ID" \
                2>/dev/null ||
                true
        )"

        if [[ -n "$TEST_TOKEN" ]]; then

            info "Existing SecretID is valid; preserving it."

            SECRET_ID="$EXISTING_SECRET_ID"

        else

            warn "Existing SecretID is invalid."
            warn "Generating a new SecretID."
        fi

        unset TEST_TOKEN
        unset EXISTING_SECRET_ID
    fi
fi

# ------------------------------------------------------------------------------
# Generate SecretID only if needed.
# ------------------------------------------------------------------------------

if [[ -z "$SECRET_ID" ]]; then

    SECRET_ID="$(
        VAULT_ADDR="$VAULT_ADDR" \
        VAULT_TOKEN="$VAULT_TOKEN" \
        vault write \
            -f \
            -field=secret_id \
            "auth/approle/role/$VAULT_APPROLE_NAME/secret-id"
    )"

    [[ -n "$SECRET_ID" ]] ||
        fail "Unable to generate Vault AppRole SecretID."

    info "Generated new AppRole SecretID."
fi

# ------------------------------------------------------------------------------
# Secure root-only storage.
# ------------------------------------------------------------------------------

sudo install \
    -d \
    -o root \
    -g root \
    -m 0700 \
    /etc/automq-vault

printf '%s\n' "$ROLE_ID" |
    sudo tee "$VAULT_ROLE_ID_FILE" \
        >/dev/null

printf '%s\n' "$SECRET_ID" |
    sudo tee "$VAULT_SECRET_ID_FILE" \
        >/dev/null

sudo chown \
    root:root \
    "$VAULT_ROLE_ID_FILE" \
    "$VAULT_SECRET_ID_FILE"

sudo chmod \
    0600 \
    "$VAULT_ROLE_ID_FILE" \
    "$VAULT_SECRET_ID_FILE"

ok "AppRole credential files installed"

# ==============================================================================
# 10. END-TO-END VALIDATION
# ==============================================================================

section "[10/10] End-to-end validation"

info "Testing AppRole login..."

TEST_TOKEN="$(
    VAULT_ADDR="$VAULT_ADDR" \
    vault write \
        -field=token \
        auth/approle/login \
        role_id="$ROLE_ID" \
        secret_id="$SECRET_ID"
)"

[[ -n "$TEST_TOKEN" ]] ||
    fail "AppRole login validation failed."

ok "AppRole login successful"

info "Testing AppRole access to Ceph secret..."

TEST_ENDPOINT="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$TEST_TOKEN" \
    vault kv get \
        -field=endpoint \
        "$VAULT_SECRET_PATH"
)"

[[ "$TEST_ENDPOINT" == "$CEPH_ENDPOINT" ]] ||
    fail "Vault endpoint validation failed.

Expected:

    $CEPH_ENDPOINT

Vault returned:

    $TEST_ENDPOINT"

ok "AppRole can read AutoMQ Ceph secret"

# ------------------------------------------------------------------------------
# Final S3 test using credentials retrieved back FROM Vault through AppRole.
# ------------------------------------------------------------------------------

TEST_ACCESS_KEY="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$TEST_TOKEN" \
    vault kv get \
        -field=access_key \
        "$VAULT_SECRET_PATH"
)"

TEST_SECRET_KEY="$(
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$TEST_TOKEN" \
    vault kv get \
        -field=secret_key \
        "$VAULT_SECRET_PATH"
)"

info "Testing Vault -> Ceph authentication..."

AWS_ACCESS_KEY_ID="$TEST_ACCESS_KEY" \
AWS_SECRET_ACCESS_KEY="$TEST_SECRET_KEY" \
AWS_DEFAULT_REGION="us-east-1" \
aws \
    --endpoint-url "$TEST_ENDPOINT" \
    s3api list-buckets \
    >/dev/null

ok "Vault -> Ceph authentication successful"

# ==============================================================================
# SUMMARY
# ==============================================================================

echo
echo "======================================================================"
echo "                    VAULT BOOTSTRAP SUCCESSFUL"
echo "======================================================================"
echo
echo "Ceph VM:"
echo "  ${CEPH_SSH_USER}@${CEPH_VM_IP}"
echo
echo "Rook Secret:"
echo "  ${ROOK_NAMESPACE}/${ROOK_S3_SECRET}"
echo
echo "Rook Endpoint:"
echo "  ${ROOK_ENDPOINT}"
echo
echo "AutoMQ RGW Endpoint:"
echo "  ${CEPH_ENDPOINT}"
echo
echo "Vault:"
echo "  ${VAULT_ADDR}"
echo
echo "Vault Secret:"
echo "  ${VAULT_SECRET_PATH}"
echo
echo "Vault Policy:"
echo "  ${VAULT_POLICY_NAME}"
echo
echo "Vault AppRole:"
echo "  ${VAULT_APPROLE_NAME}"
echo
echo "Role ID:"
echo "  ${VAULT_ROLE_ID_FILE}"
echo
echo "Secret ID:"
echo "  ${VAULT_SECRET_ID_FILE}"
echo
echo "----------------------------------------------------------------------"
echo "STATUS"
echo "----------------------------------------------------------------------"
echo
echo "  Passwordless Ceph SSH       PASS"
echo "  Rook credential retrieval   PASS"
echo "  Ceph RGW connectivity       PASS"
echo "  Ceph S3 authentication      PASS"
echo "  Vault                       PASS"
echo "  Vault KV                    PASS"
echo "  Vault policy                PASS"
echo "  Vault AppRole               PASS"
echo "  AppRole credentials         PASS"
echo "  Vault -> Ceph               PASS"
echo
echo "Next:"
echo
echo "    bash deploy-automq.sh"
echo
echo "======================================================================"
