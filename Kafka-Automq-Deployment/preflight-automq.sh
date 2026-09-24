#!/usr/bin/env bash
set -Eeuo pipefail
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
cd "$(dirname "${BASH_SOURCE[0]}")"
echo "===== Vault ====="
vault status || true
if vault status -format=json 2>/dev/null | jq -e '.sealed == true' >/dev/null; then
  echo
  echo "Vault is sealed. Run: vault operator unseal"
  exit 21
fi
sudo test -s /etc/automq-vault/role-id || { echo "Missing Role ID; run bootstrap-vault.sh as an authenticated Vault admin."; exit 1; }
sudo test -s /etc/automq-vault/secret-id || { echo "Missing Secret ID; run bootstrap-vault.sh as an authenticated Vault admin."; exit 1; }
echo "[PASS] Vault prerequisites ready"
echo "Next: bash deploy-automq.sh"

