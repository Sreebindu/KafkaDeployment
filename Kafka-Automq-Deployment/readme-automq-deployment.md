AutoMQ Deployment – Prerequisites, Dependencies, and Runbook

This README documents the prerequisites and operational steps for the current deploy-automq.sh deployment on the AutoMQ VM.

1. Deployment architecture

Current configuration used by the script:

AutoMQ host/VM: 192.168.10.70

Ceph RGW/S3 endpoint: http://192.168.10.71:7480

Vault API: http://127.0.0.1:8200

Vault secret path: automq/ceph

kind cluster: automq

AutoMQ namespace: automq

Conduktor namespace: conduktor

S3 buckets: automq-data, automq-wal

Kafka internal endpoint: automq-broker.automq.svc.cluster.local:9092

Conduktor Console: http://192.168.10.70:8080

The intended credential flow is:

Vault -> AppRole authentication -> Ceph credentials -> Kubernetes Secret -> AutoMQ -> Ceph RGW

2. Required VM/network prerequisites

Before running the deployment, ensure:

The VM has network access to the Ceph RGW at 192.168.10.71:7480.

TCP port 8080 on the AutoMQ VM is available for Conduktor and allowed by any host/network firewall if remote access is required.

DNS and outbound HTTPS work so packages and binaries can be downloaded when missing.

The user running the script has sudo access.

The VM has sufficient CPU, RAM, and disk for Docker, a three-node kind cluster, AutoMQ, and Conduktor.

Docker networking/iptables forwarding is not blocked by host security policy.

Basic checks:

ping -c 2 192.168.10.71
curl -I --max-time 10 http://192.168.10.71:7480 || true
ss -lntp | grep ':8080' || true

3. Repository files required

Run the deployment from ~/KafkaDeployment. The current script requires at least:

deploy-automq.sh
automq-controller.yaml
automq-broker.yaml
conduktor.yaml

A kind configuration is optional. The script looks for kind-config.yaml or kind-cluster.yaml; otherwise it creates a temporary default configuration with one control-plane and two worker nodes.

Check:

cd ~/KafkaDeployment
ls -l deploy-automq.sh automq-controller.yaml automq-broker.yaml conduktor.yaml
bash -n deploy-automq.sh

4. Software dependencies

The deployment uses:

Bash

sudo

curl

wget

jq

unzip

ca-certificates

gnupg

lsb-release

netcat-openbsd (nc)

socat

openssl

Docker Engine

kubectl

kind

AWS CLI v2

HashiCorp Vault CLI/server

The script installs/checks the ordinary packages, Docker, kubectl, kind, and AWS CLI as needed. Vault is intentionally different: the script expects the existing persistent Vault installation and does not reinstall, initialize, or recreate it.

Useful checks:

docker --version
kubectl version --client
kind --version
aws --version
vault version

5. One-time Vault configuration

Vault must be configured before the deployment script can succeed. Do this only for a new Vault environment. Do not repeat Vault initialization on an already initialized Vault.

Set the address:

export VAULT_ADDR=http://127.0.0.1:8200

Verify:

vault status

The required state before deployment is:

Initialized    true
Sealed         false

If the existing Vault is sealed, unseal it with the securely stored unseal key:

vault operator unseal

Never place the unseal key or root token in deploy-automq.sh, Git, YAML manifests, or this README.

Required Vault KV engine

The deployment expects the KV v2 engine mounted at automq/.

For a new environment only:

vault secrets enable -path=automq kv-v2

Do not run that command if automq/ already exists.

Check:

vault secrets list

Required AppRole auth method

For a new environment only:

vault auth enable approle

Check:

vault auth list

AutoMQ Vault policy

The AppRole needs read access to the KV v2 data path. Example policy:

path "automq/data/ceph" {
  capabilities = ["read"]
}

path "automq/metadata/ceph" {
  capabilities = ["read"]
}

Save it temporarily as automq-policy.hcl, then apply it:

vault policy write automq-policy automq-policy.hcl
rm -f automq-policy.hcl

AutoMQ AppRole

For initial setup:

vault write auth/approle/role/automq \
  token_policies="automq-policy" \
  token_ttl="1h" \
  token_max_ttl="4h"

Check:

vault read auth/approle/role/automq

Store AppRole credentials securely

The deployment expects:

/etc/automq-vault/role-id
/etc/automq-vault/secret-id

Create the directory:

sudo install -d -m 700 -o root -g root /etc/automq-vault

Store the Role ID:

vault read -field=role_id auth/approle/role/automq | \
  sudo tee /etc/automq-vault/role-id >/dev/null

Generate/store the Secret ID:

vault write -f -field=secret_id auth/approle/role/automq/secret-id | \
  sudo tee /etc/automq-vault/secret-id >/dev/null

Secure them:

sudo chown root:root /etc/automq-vault/role-id /etc/automq-vault/secret-id
sudo chmod 600 /etc/automq-vault/role-id /etc/automq-vault/secret-id
sudo ls -l /etc/automq-vault/

The normal user may fail test -s /etc/automq-vault/role-id because the file is intentionally root-only. The deployment script checks and reads these files using sudo.

6. Store Ceph credentials in Vault

The required Vault secret contains these fields:

access_key

secret_key

endpoint

With the actual Ceph credentials available in your shell, store them once with:

vault kv put automq/ceph \
  access_key="$CEPH_ACCESS_KEY" \
  secret_key="$CEPH_SECRET_KEY" \
  endpoint="http://192.168.10.71:7480"

Do not put the real access key or secret key in this README, Git, or deployment YAML.

Verify fields without printing the secrets themselves:

vault kv get -field=endpoint automq/ceph

test -n "$(vault kv get -field=access_key automq/ceph)" && echo 'Access key: PRESENT'
test -n "$(vault kv get -field=secret_key automq/ceph)" && echo 'Secret key: PRESENT'

7. Test the AppRole before deployment

export VAULT_ADDR=http://127.0.0.1:8200

ROLE_ID="$(sudo cat /etc/automq-vault/role-id)"
SECRET_ID="$(sudo cat /etc/automq-vault/secret-id)"

TEST_TOKEN="$(
  vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" \
    secret_id="$SECRET_ID"
)"

[[ -n "$TEST_TOKEN" ]] && echo 'Vault AppRole login: PASS'

VAULT_TOKEN="$TEST_TOKEN" \
  vault kv get -field=endpoint automq/ceph

unset ROLE_ID SECRET_ID TEST_TOKEN

Expected endpoint:

http://192.168.10.71:7480

8. Docker requirement

kind requires access to the Docker API through /var/run/docker.sock. The script starts/enables Docker and adds the current user to the docker group if necessary. It can re-execute itself under that group when the current shell has stale group membership.

Verify manually if needed:

sudo systemctl status docker --no-pager
docker info
id
ls -l /var/run/docker.sock

docker info must work without sudo by the time kind is executed.

9. Ceph/S3 requirements

Ceph RGW must accept the credentials stored in Vault. The deployment checks S3 authentication and ensures these buckets exist:

automq-data
automq-wal

Existing buckets are reused rather than recreated.

Manual test after obtaining credentials from Vault:

aws --endpoint-url http://192.168.10.71:7480 s3 ls

The AWS CLI must have the correct Ceph access/secret keys in its environment for this manual command.

10. Kubernetes/AutoMQ requirements

The script creates/reuses the kind cluster automq, switches kubectl to context kind-automq, waits for nodes, creates namespaces, and creates/updates Kubernetes Secret automq-s3-credentials in namespace automq.

The AutoMQ YAML should consume the S3 credentials through Kubernetes secretKeyRef. Do not hard-code Ceph credentials in YAML.

Useful checks:

kind get clusters
kubectl config current-context
kubectl get nodes -o wide
kubectl get pods -n automq -o wide
kubectl get svc -n automq -o wide

The Kafka internal service used by the deployment is:

automq-broker.automq.svc.cluster.local:9092

The script's Kafka validation discovers the broker Pod IP dynamically and imposes a 30-second timeout so an unavailable listener does not cause an endless deployment loop.

11. Conduktor requirements

The repository must contain conduktor.yaml. The script applies it to Kubernetes and expects the service:

conduktor/conduktor-console

The script automatically starts this background port-forward:

kubectl port-forward \
  -n conduktor \
  svc/conduktor-console \
  8080:8080 \
  --address 0.0.0.0

The script records the process/log under:

/tmp/conduktor-port-forward.pid
/tmp/conduktor-port-forward.log

Check it with:

cat /tmp/conduktor-port-forward.pid
cat /tmp/conduktor-port-forward.log
ss -lntp | grep ':8080'
curl -I http://127.0.0.1:8080

From another machine, use:

http://192.168.10.70:8080

Note: this nohup kubectl port-forward survives the deployment shell exiting, but /tmp and the process do not provide a permanent boot-time service. After a VM reboot, rerunning deploy-automq.sh recreates the port-forward. If boot-time availability without rerunning the deployment is required, use a dedicated systemd service or another Kubernetes exposure method.

12. Normal deployment procedure

Before each normal run:

cd ~/KafkaDeployment
export VAULT_ADDR=http://127.0.0.1:8200
vault status

If Vault says Sealed true:

vault operator unseal

Confirm:

vault status | grep -E 'Initialized|Sealed'

Then run:

bash -n deploy-automq.sh && echo 'SCRIPT SYNTAX: PASS'
bash deploy-automq.sh

13. What happens on repeat runs

The deployment is intended to reuse persistent resources. In particular, it should not:

reinitialize Vault;

regenerate the Vault root token or unseal key;

erase Vault Raft data;

recreate the AppRole on every run;

overwrite the Ceph credentials in Vault;

delete/recreate existing S3 buckets;

delete the kind cluster simply because it already exists.

It may safely re-apply Kubernetes manifests and update the Kubernetes Secret from the current Vault values.

14. After a VM reboot

With the current Shamir seal configuration, Vault may start sealed after reboot. The expected procedure is:

export VAULT_ADDR=http://127.0.0.1:8200
vault status

If sealed:

vault operator unseal

Then:

cd ~/KafkaDeployment
bash deploy-automq.sh

The script will reuse the existing Vault data, AppRole, Ceph secret, S3 buckets, and existing kind resources where applicable, and restore the Conduktor port-forward.

15. Post-deployment validation

Run these checks after deployment:

# Vault
export VAULT_ADDR=http://127.0.0.1:8200
vault status | grep -E 'Initialized|Sealed'

# Docker
docker info >/dev/null && echo 'Docker: PASS'

# kind/Kubernetes
kind get clusters
kubectl get nodes -o wide

# AutoMQ
kubectl get pods,svc -n automq -o wide
kubectl logs -n automq automq-broker-0 --tail=100

# Conduktor
kubectl get pods,svc -n conduktor -o wide
curl -I --max-time 10 http://127.0.0.1:8080

# Port-forward
pgrep -af 'kubectl port-forward.*conduktor-console.*8080:8080'
cat /tmp/conduktor-port-forward.log

For Kafka, the broker Pod IP can be retrieved with:

BROKER_IP="$(kubectl get pod -n automq automq-broker-0 -o jsonpath='{.status.podIP}')"

echo "$BROKER_IP"

kubectl exec -n automq automq-broker-0 -- \
  /opt/kafka/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BROKER_IP}:9092" \
  --list

16. Common failures

Vault says Sealed true

This is not a deployment-script failure. Unseal the existing Vault:

export VAULT_ADDR=http://127.0.0.1:8200
vault operator unseal

Do not initialize Vault again.

Missing Vault Role ID

Check using sudo because the files are root-only:

sudo test -s /etc/automq-vault/role-id && echo PASS
sudo test -s /etc/automq-vault/secret-id && echo PASS
sudo ls -l /etc/automq-vault/

kind reports Docker socket permission denied

id
getent group docker
ls -l /var/run/docker.sock
docker info

The deployment script attempts to correct membership and re-execute under the Docker group.

Kafka warns about localhost:9092

Do not validate this deployment against localhost:9092 unless the broker is explicitly configured to listen there. The script discovers the broker Pod IP and validates ${BROKER_IP}:9092 with a timeout.

Conduktor is running but the browser cannot connect

kubectl get pods,svc -n conduktor
pgrep -af 'kubectl port-forward.*conduktor-console'
ss -lntp | grep ':8080'
cat /tmp/conduktor-port-forward.log
curl -I http://127.0.0.1:8080

Also verify the VM/network firewall permits inbound TCP/8080 when accessing 192.168.10.70:8080 remotely.

Port 8080 is already occupied

sudo ss -lntp | grep ':8080'

Stop or reconfigure the conflicting service before running the deployment.

17. Security notes

Never commit Vault root tokens, unseal keys, Ceph access keys, Ceph secret keys, or AppRole Secret IDs to Git.

Keep /etc/automq-vault/role-id and /etc/automq-vault/secret-id root-owned with mode 600 as configured.

Do not place Ceph credentials directly into AutoMQ YAML; use the Kubernetes Secret.

kubectl port-forward --address 0.0.0.0 exposes Conduktor on every VM interface. Restrict TCP/8080 with firewall/network policy to trusted clients.

The current endpoints use plain HTTP. For a production deployment, TLS and appropriate certificate/identity management should be considered separately.

18. Quick run checklist

Before bash deploy-automq.sh, confirm:

[ ] automq-controller.yaml exists
[ ] automq-broker.yaml exists
[ ] conduktor.yaml exists
[ ] Ceph RGW 192.168.10.71:7480 is reachable
[ ] Vault service is running
[ ] Vault Initialized=true
[ ] Vault Sealed=false
[ ] automq/ceph contains access_key, secret_key, endpoint
[ ] /etc/automq-vault/role-id exists and is non-empty
[ ] /etc/automq-vault/secret-id exists and is non-empty
[ ] AutoMQ AppRole can read automq/ceph
[ ] Docker daemon works
[ ] TCP/8080 is available for Conduktor
[ ] deploy-automq.sh passes bash -n

Then:

cd ~/KafkaDeployment
export VAULT_ADDR=http://127.0.0.1:8200
bash deploy-automq.sh
