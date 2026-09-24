#!/usr/bin/env bash
set -Eeuo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_ROLE_NAME="automq"
VAULT_POLICY_NAME="automq-policy"
VAULT_KV_MOUNT="automq"
VAULT_SECRET_PATH="automq/ceph"
CRED_DIR="/etc/automq-vault"
ROLE_ID_FILE="$CRED_DIR/role-id"
SECRET_ID_FILE="$CRED_DIR/secret-id"
CEPH_DEFAULT_ENDPOINT="http://192.168.10.71:7480"
export VAULT_ADDR

info(){ printf '[INFO] %s\n' "$*"; }
ok(){ printf '[PASS] %s\n' "$*"; }
fail(){ printf '\n[FAIL] %s\n\n' "$*" >&2; exit 1; }

command -v vault >/dev/null 2>&1 || fail "Vault CLI is not installed. Install/configure the Vault server first."
command -v jq >/dev/null 2>&1 || fail "jq is required. Install it with: sudo apt-get install -y jq"

if ! systemctl is-active --quiet vault; then
  info "Starting existing Vault service..."
  sudo systemctl start vault
  sleep 2
fi

STATUS="$(vault status -format=json 2>/dev/null || true)"
[[ -n "$STATUS" ]] || fail "Cannot reach Vault at $VAULT_ADDR"
INITIALIZED="$(jq -r '.initialized' <<<"$STATUS")"
SEALED="$(jq -r '.sealed' <<<"$STATUS")"

[[ "$INITIALIZED" == "true" ]] || fail "Vault is not initialized. This bootstrap intentionally will NOT initialize Vault automatically. Initialize Vault once as an administrator, securely retain the unseal/root recovery material, then rerun this script."

if [[ "$SEALED" == "true" ]]; then
  echo "Vault is sealed. Unseal it in another command with:"
  echo "  export VAULT_ADDR=$VAULT_ADDR"
  echo "  vault operator unseal"
  exit 21
fi
ok "Vault is initialized and unsealed"

# Administrative configuration requires an authenticated admin/root token.
if ! vault token lookup >/dev/null 2>&1; then
  fail "No administrative Vault token is active. Run 'vault login' with an authorized admin token, then rerun bootstrap-vault.sh."
fi

if vault secrets list -format=json | jq -e --arg p "${VAULT_KV_MOUNT}/" 'has($p)' >/dev/null; then
  info "KV mount already exists: ${VAULT_KV_MOUNT}/"
else
  vault secrets enable -path="$VAULT_KV_MOUNT" -version=2 kv
  ok "Enabled KV v2 at ${VAULT_KV_MOUNT}/"
fi

if vault auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
  info "AppRole auth already enabled"
else
  vault auth enable approle
  ok "Enabled AppRole authentication"
fi

POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT
cat >"$POLICY_FILE" <<'POLICY'
path "automq/data/ceph" {
  capabilities = ["read"]
}
path "automq/metadata/ceph" {
  capabilities = ["read"]
}
POLICY
vault policy write "$VAULT_POLICY_NAME" "$POLICY_FILE" >/dev/null
ok "Policy configured: $VAULT_POLICY_NAME"

vault write "auth/approle/role/$VAULT_ROLE_NAME" \
  token_policies="$VAULT_POLICY_NAME" \
  token_ttl="1h" \
  token_max_ttl="4h" \
  secret_id_ttl="0" \
  secret_id_num_uses="0" >/dev/null
ok "AppRole configured: $VAULT_ROLE_NAME"

ROLE_ID="$(vault read -field=role_id "auth/approle/role/$VAULT_ROLE_NAME/role-id")"

sudo install -d -o root -g root -m 0700 "$CRED_DIR"
printf '%s\n' "$ROLE_ID" | sudo tee "$ROLE_ID_FILE" >/dev/null
sudo chown root:root "$ROLE_ID_FILE"
sudo chmod 0600 "$ROLE_ID_FILE"

# Preserve a working SecretID. Generate one only if missing/invalid.
SECRET_ID=""
if sudo test -s "$SECRET_ID_FILE"; then
  SECRET_ID="$(sudo cat "$SECRET_ID_FILE")"
  if ! vault write -format=json "auth/approle/role/$VAULT_ROLE_NAME/secret-id/lookup" secret_id="$SECRET_ID" >/dev/null 2>&1; then
    info "Stored SecretID is invalid; generating a replacement"
    SECRET_ID=""
  else
    info "Existing SecretID is valid; preserving it"
  fi
fi
if [[ -z "$SECRET_ID" ]]; then
  SECRET_ID="$(vault write -f -field=secret_id "auth/approle/role/$VAULT_ROLE_NAME/secret-id")"
  printf '%s\n' "$SECRET_ID" | sudo tee "$SECRET_ID_FILE" >/dev/null
  sudo chown root:root "$SECRET_ID_FILE"
  sudo chmod 0600 "$SECRET_ID_FILE"
  ok "Generated and securely stored SecretID"
fi

if vault kv get "$VAULT_SECRET_PATH" >/dev/null 2>&1; then
  info "Existing Ceph secret found at $VAULT_SECRET_PATH; preserving it"
else
  echo
  echo "Ceph secret is not configured yet."
  read -r -p "Ceph access key: " CEPH_ACCESS_KEY
  read -r -s -p "Ceph secret key: " CEPH_SECRET_KEY
  echo
  read -r -p "Ceph RGW endpoint [$CEPH_DEFAULT_ENDPOINT]: " CEPH_ENDPOINT
  CEPH_ENDPOINT="${CEPH_ENDPOINT:-$CEPH_DEFAULT_ENDPOINT}"
  [[ -n "$CEPH_ACCESS_KEY" && -n "$CEPH_SECRET_KEY" ]] || fail "Ceph credentials cannot be empty."
  vault kv put "$VAULT_SECRET_PATH" access_key="$CEPH_ACCESS_KEY" secret_key="$CEPH_SECRET_KEY" endpoint="$CEPH_ENDPOINT" >/dev/null
  unset CEPH_ACCESS_KEY CEPH_SECRET_KEY
  ok "Ceph secret stored at $VAULT_SECRET_PATH"
fi

TEST_TOKEN="$(vault write -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")"
[[ -n "$TEST_TOKEN" ]] || fail "AppRole login test failed"
TEST_ENDPOINT="$(VAULT_TOKEN="$TEST_TOKEN" vault kv get -field=endpoint "$VAULT_SECRET_PATH")"
[[ -n "$TEST_ENDPOINT" ]] || fail "AppRole cannot read Ceph endpoint"
unset TEST_TOKEN SECRET_ID ROLE_ID

sudo test -s "$ROLE_ID_FILE" || fail "Role ID file missing"
sudo test -s "$SECRET_ID_FILE" || fail "Secret ID file missing"

ok "Vault AutoMQ bootstrap complete"
echo "Ceph endpoint: $TEST_ENDPOINT"
echo "Next: bash deploy-automq.sh"

