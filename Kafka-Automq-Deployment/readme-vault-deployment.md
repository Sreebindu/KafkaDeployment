I recommend keeping Vault bootstrap, pre-run checking, and the actual AutoMQ deployment separate.

I created these two scripts for you:

Download bootstrap-vault.sh — one-time Vault/AutoMQ configuration and repair.
Download preflight-automq.sh — quick check before normal deployment runs.

HashiCorp documents AppRole specifically for machine/application authentication, using RoleID + SecretID to obtain a Vault token. Your automq/ KV-v2 mount also follows Vault's documented KV-v2 configuration.

1. Put the scripts in your repository

Your directory should ultimately look like:

~/KafkaDeployment/
├── bootstrap-vault.sh
├── preflight-automq.sh
├── deploy-automq.sh
├── automq-controller.yaml
├── automq-broker.yaml
├── conduktor.yaml
└── kind-cluster.yaml

Then:

cd ~/KafkaDeployment

chmod +x bootstrap-vault.sh
chmod +x preflight-automq.sh
chmod +x deploy-automq.sh

bash -n bootstrap-vault.sh
bash -n preflight-automq.sh
bash -n deploy-automq.sh

All three should return without syntax errors.

2. On your CURRENT VM

Your current Vault is already initialized and configured. Do not initialize it again.

First:

export VAULT_ADDR=http://127.0.0.1:8200

vault status

If you see:

Initialized    true
Sealed         false

you're good.

If you see:

Initialized    true
Sealed         true

run:

vault operator unseal

Enter your existing unseal key.

Then:

vault status

Confirm:

Sealed    false
You do NOT need to run bootstrap-vault.sh on this VM

Because you've already successfully established:

automq/
approle/
automq-policy
auth/approle/role/automq
automq/ceph
/etc/automq-vault/role-id
/etc/automq-vault/secret-id

For this VM, just run:

cd ~/KafkaDeployment

./preflight-automq.sh

You should get:

[PASS] Vault prerequisites ready
Next: bash deploy-automq.sh

Then:

bash deploy-automq.sh
3. On a NEW VM

This is where bootstrap-vault.sh becomes useful.

There are two distinct phases.

Phase A — Vault server installation/initialization

The bootstrap script deliberately does not automatically initialize Vault.

That is intentional because initialization produces extremely sensitive recovery/unseal/root material and should not happen invisibly inside your application deployment.

After installing/configuring the Vault server, check:

export VAULT_ADDR=http://127.0.0.1:8200

vault status

If this is a genuinely brand-new Vault and it reports:

Initialized    false

initialize it once according to the seal/recovery design you intend to use.

For your current lab architecture you previously used one Shamir share and threshold one. Be aware that this is convenient for a lab but provides essentially no redundancy if that single unseal key is lost.

After initialization, securely retain the initialization output outside the repository.

Then unseal:

vault operator unseal

and authenticate as the Vault administrator:

vault login

Do not put the root token or unseal key in:

deploy-automq.sh
bootstrap-vault.sh
README.md
Git
Kubernetes YAML
4. Run the bootstrap

Once Vault says:

Initialized    true
Sealed         false

and your current Vault CLI session has an administrative token:

cd ~/KafkaDeployment

export VAULT_ADDR=http://127.0.0.1:8200

./bootstrap-vault.sh

The bootstrap will check/create the following.

Vault
 │
 ├── KV v2
 │    └── automq/
 │
 ├── AppRole
 │    └── automq
 │
 ├── Policy
 │    └── automq-policy
 │
 └── Secret
      └── automq/ceph

It creates the policy giving AutoMQ read access to its Ceph secret.

It creates/configures:

auth/approle/role/automq

and retrieves the RoleID.

Vault generates SecretIDs for AppRole authentication; HashiCorp describes the RoleID as analogous to a username and SecretID as the secret/password component.

The script securely writes them to:

/etc/automq-vault/role-id
/etc/automq-vault/secret-id

with root-only permissions.

5. Existing SecretIDs are preserved

This is important.

The bootstrap does not blindly generate a new SecretID every time.

It checks:

/etc/automq-vault/secret-id

and asks Vault whether that SecretID is still valid.

If valid:

Existing SecretID is valid; preserving it

If invalid/missing, it generates a replacement.

Vault provides a SecretID lookup mechanism specifically for checking the properties of an issued SecretID.

6. Ceph credentials

If this already exists:

automq/ceph

the bootstrap preserves it.

It will not overwrite your working Ceph credentials.

You should see:

[INFO] Existing Ceph secret found at automq/ceph; preserving it

On a completely new installation where the secret doesn't exist, it asks:

Ceph access key:
Ceph secret key:
Ceph RGW endpoint [http://192.168.10.71:7480]:

The secret key input isn't echoed.

It then creates:

automq/ceph

containing:

access_key
secret_key
endpoint
7. Bootstrap verifies everything

At the end it performs an actual AppRole login:

RoleID
   +
SecretID
   ↓
AppRole login
   ↓
Vault token
   ↓
automq/ceph

and verifies that the resulting AppRole token can read the Ceph endpoint.

That is the same authentication workflow HashiCorp documents for applications using AppRole.

Successful output should end approximately with:

[PASS] Vault AutoMQ bootstrap complete
Ceph endpoint: http://192.168.10.71:7480
Next: bash deploy-automq.sh
8. Then run your deployment

Run:

./preflight-automq.sh

If successful:

[PASS] Vault prerequisites ready
Next: bash deploy-automq.sh

Then:

bash deploy-automq.sh

Your deployment continues through:

Vault
  ↓
AppRole
  ↓
automq/ceph
  ↓
Kubernetes Secret
  ↓
AutoMQ
  ↓
Ceph RGW

kind Kubernetes
  ├── AutoMQ
  └── Conduktor
       ↓
0.0.0.0:8080
9. Normal procedure after a VM reboot

You do not run bootstrap again just because the VM rebooted.

Run:

cd ~/KafkaDeployment

export VAULT_ADDR=http://127.0.0.1:8200

vault status

With your current Shamir configuration, Vault may be sealed following a service/VM restart.

If:

Sealed    true

run:

vault operator unseal

Then:

./preflight-automq.sh

and finally:

bash deploy-automq.sh

So your normal reboot workflow is simply:

cd ~/KafkaDeployment
export VAULT_ADDR=http://127.0.0.1:8200

vault status

# Only when Sealed=true:
vault operator unseal

./preflight-automq.sh
bash deploy-automq.sh
Important distinction

Think of the three scripts this way:

NEW VM
  │
  ├─ Install/configure Vault server
  │
  ├─ Initialize Vault ONCE
  │
  ├─ Unseal
  │
  ├─ vault login
  │
  └─ bootstrap-vault.sh       ← ONE-TIME configuration
                 │
                 ▼
         preflight-automq.sh  ← SAFETY CHECK
                 │
                 ▼
         deploy-automq.sh     ← NORMAL DEPLOYMENT


EXISTING VM / REBOOT
  │
  ├─ Unseal Vault if necessary
  │
  ├─ preflight-automq.sh
  │
  └─ deploy-automq.sh

I would keep initialization and unseal material completely outside deploy-automq.sh. That way a mistake in the AutoMQ deployment cannot accidentally turn into a destructive Vault operation.
