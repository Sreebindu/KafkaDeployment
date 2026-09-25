
AutoMQ + Ceph RGW + Vault - Simple Prerequisites

PURPOSE

Complete these three prerequisites on the AutoMQ VM before running:

    bash deploy-automq.sh

Environment: AutoMQ VM : 192.168.10.70 Ceph VM : 192.168.10.71 Ceph user
: rook-ceph Vault : http://127.0.0.1:8200

====================================================================== 
1. CONFIGURE PASSWORDLESS SSH FROM AUTOMQ TO CEPH
======================================================================

Run these commands on the AutoMQ VM (192.168.10.70).

Create the dedicated SSH key:

    ssh-keygen -t ed25519 \
      -f ~/.ssh/automq-ceph \
      -C "automq-to-ceph"

For unattended operation, press Enter twice when asked for a passphrase.

Copy the public key to the Ceph VM:

    ssh-copy-id \
      -i ~/.ssh/automq-ceph.pub \
      rook-ceph@192.168.10.71

Enter the rook-ceph password when prompted. This is normally required
only during the initial setup.

Verify passwordless SSH:

    ssh \
      -i ~/.ssh/automq-ceph \
      -o BatchMode=yes \
      rook-ceph@192.168.10.71 \
      'hostname'

Expected:

    rook-ceph

======================================================================
2. INSTALL, INITIALIZE, AND UNSEAL VAULT
======================================================================

Set the Vault address:

    export VAULT_ADDR=http://127.0.0.1:8200

Check Vault:

    vault status

If Vault is not installed, run the prerequisite/preflight installation
process before continuing.

If Vault is installed and reports:

    Initialized    false

initialize Vault ONCE:

    vault operator init \
      -key-shares=1 \
      -key-threshold=1

Securely save the generated:

    - Unseal Key
    - Initial Root Token

Do NOT store these credentials in the repository, scripts, YAML files,
or documentation.

After initialization, unseal Vault:

    vault operator unseal

Enter the unseal key when prompted.

Verify:

    vault status | grep -E 'Initialized|Sealed'

Required result:

    Initialized    true
    Sealed         false

IMPORTANT:

Never run “vault operator init” again when Vault already reports:

    Initialized    true

After a Vault service restart or VM reboot, Vault may become sealed
again. In that case, run:

    export VAULT_ADDR=http://127.0.0.1:8200
    vault operator unseal

Then verify:

    vault status | grep -E 'Initialized|Sealed'

======================================================================
3. BOOTSTRAP VAULT WITH CEPH CREDENTIALS
======================================================================

Go to the deployment repository:

    cd ~/KafkaDeployment/Kafka-Automq-Deployment

Check the bootstrap script syntax:

    bash -n bootstrap-vault.sh && echo "SYNTAX: PASS"

Run the bootstrap:

    bash bootstrap-vault.sh

When prompted for:

    Vault admin/root token:

enter the Vault root/admin token.

The bootstrap script should:

    - Verify Vault is initialized and unsealed
    - Verify passwordless SSH to the Ceph VM
    - Retrieve the Rook S3 credentials
    - Validate Ceph RGW connectivity
    - Validate Ceph S3 authentication
    - Store/synchronize Ceph credentials in Vault
    - Configure the AutoMQ Vault policy
    - Configure the AutoMQ AppRole
    - Create/update the AppRole Role ID
    - Create/update the AppRole Secret ID
    - Validate AppRole authentication
    - Validate Vault -> Ceph authentication

Successful completion should display:

    VAULT BOOTSTRAP SUCCESSFUL

and PASS results for the bootstrap validation checks.

======================================================================
RUN AUTOMQ DEPLOYMENT
======================================================================

After all three prerequisites succeed:

    cd ~/KafkaDeployment/Kafka-Automq-Deployment

    bash -n deploy-automq.sh && echo "SYNTAX: PASS"

    bash deploy-automq.sh

======================================================================
SIMPLE EXECUTION FLOW
======================================================================

    1. AutoMQ -> Ceph passwordless SSH
                    |
                    v
    2. Vault installed + initialized + unsealed
                    |
                    v
    3. bootstrap-vault.sh
                    |
                    v
       VAULT BOOTSTRAP SUCCESSFUL
                    |
                    v
    4. deploy-automq.sh

======================================================================
NORMAL RERUN / AFTER VM REBOOT
======================================================================

You do NOT need to recreate the SSH key. You do NOT need to run
ssh-copy-id again. You do NOT initialize Vault again.

Check Vault:

    export VAULT_ADDR=http://127.0.0.1:8200
    sudo systemctl start vault
    vault status

If Vault reports Sealed=true:

    vault operator unseal

Verify:

    vault status | grep -E 'Initialized|Sealed'

Required:

    Initialized    true
    Sealed         false

Then run:

    cd ~/KafkaDeployment/Kafka-Automq-Deployment
    bash deploy-automq.sh

======================================================================
IMPORTANT
======================================================================

Never store the following in Git or the deployment repository:

    - Vault root token
    - Vault unseal key
    - Ceph AccessKey
    - Ceph SecretKey
    - SSH private key

Never initialize an already initialized Vault.

If Ceph S3 credentials are changed or rotated, run:

    bash bootstrap-vault.sh
    bash deploy-automq.sh

