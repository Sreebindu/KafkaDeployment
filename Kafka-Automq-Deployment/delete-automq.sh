#!/usr/bin/bash

# ==============================================================================
# Safe AutoMQ kind Cluster Cleanup
#
# Removes ONLY:
#   - kind cluster named "automq"
#   - leftover Docker containers belonging to that kind cluster
#
# Checks:
#   - port 30094
#   - port 30080
#
# DOES NOT REMOVE:
#   - ~/KafkaDeployment
#   - repository files
#   - Vault
#   - Vault data / AppRole
#   - Ceph
#   - Ceph buckets
#   - SSH keys
# ==============================================================================

set -Eeuo pipefail

CLUSTER_NAME="automq"

echo
echo "======================================================================"
echo " AutoMQ kind Cluster Cleanup"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Show current state
# ------------------------------------------------------------------------------

echo
echo "[INFO] Existing kind clusters:"
kind get clusters 2>/dev/null || true

echo
echo "[INFO] Existing AutoMQ kind containers:"
docker ps -a \
    --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}' \
    || true


# ------------------------------------------------------------------------------
# 2. Delete kind cluster
# ------------------------------------------------------------------------------

echo
echo "[INFO] Deleting kind cluster: ${CLUSTER_NAME}"

kind delete cluster \
    --name "$CLUSTER_NAME" \
    2>/dev/null || true

echo "[PASS] kind delete completed"


# ------------------------------------------------------------------------------
# 3. Remove leftover containers belonging ONLY to automq
# ------------------------------------------------------------------------------

echo
echo "[INFO] Checking for leftover AutoMQ kind containers..."

LEFTOVERS="$(
    docker ps -aq \
        --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
        2>/dev/null || true
)"

if [[ -n "$LEFTOVERS" ]]; then

    echo "[INFO] Removing leftover AutoMQ kind containers..."

    while IFS= read -r container
    do
        [[ -n "$container" ]] || continue

        NAME="$(
            docker inspect \
                --format '{{.Name}}' \
                "$container" \
                2>/dev/null |
            sed 's#^/##'
        )"

        echo "[INFO] Removing container: ${NAME:-$container}"

        docker rm -f "$container" >/dev/null

    done <<< "$LEFTOVERS"

else

    echo "[PASS] No leftover AutoMQ kind containers"

fi


# ------------------------------------------------------------------------------
# 4. Verify cluster removal
# ------------------------------------------------------------------------------

echo
echo "[INFO] Verifying cluster removal..."

if kind get clusters 2>/dev/null |
   grep -qx "$CLUSTER_NAME"
then

    echo "[FAIL] kind cluster '$CLUSTER_NAME' still exists."
    exit 1

else

    echo "[PASS] kind cluster '$CLUSTER_NAME' removed"

fi


# ------------------------------------------------------------------------------
# 5. Verify no AutoMQ kind containers remain
# ------------------------------------------------------------------------------

REMAINING="$(
    docker ps -aq \
        --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
        2>/dev/null || true
)"

if [[ -n "$REMAINING" ]]; then

    echo "[FAIL] AutoMQ kind containers still remain:"
    docker ps -a \
        --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}"

    exit 1
fi

echo "[PASS] No AutoMQ kind containers remain"


# ------------------------------------------------------------------------------
# 6. Check required host ports
# ------------------------------------------------------------------------------

echo
echo "[INFO] Checking required host ports..."

PORT_PROBLEM=0

for PORT in 30094 30080
do

    if ss -lnt |
       awk '{print $4}' |
       grep -Eq "(^|:)${PORT}$"
    then

        echo
        echo "[WARN] Port ${PORT} is still occupied."

        sudo ss -lntp 2>/dev/null |
            grep ":${PORT}" ||
            true

        echo
        echo "[INFO] Docker containers referencing port ${PORT}:"

        docker ps \
            --format 'table {{.ID}}\t{{.Names}}\t{{.Ports}}' |
            grep "${PORT}" ||
            true

        PORT_PROBLEM=1

    else

        echo "[PASS] Port ${PORT} is free"

    fi

done


# ------------------------------------------------------------------------------
# 7. Final result
# ------------------------------------------------------------------------------

echo
echo "======================================================================"

if [[ "$PORT_PROBLEM" -eq 0 ]]; then

    echo " CLEANUP SUCCESSFUL"
    echo "======================================================================"
    echo
    echo "kind cluster 'automq' has been removed."
    echo "Ports 30094 and 30080 are free."
    echo
    echo "You can now run:"
    echo
    echo "    bash deploy-automq.sh"
    echo

else

    echo " CLEANUP COMPLETED - PORT CONFLICT REMAINS"
    echo "======================================================================"
    echo
    echo "The AutoMQ kind cluster was removed,"
    echo "but another process is using a required port."
    echo
    echo "Review the process information above before redeploying."
    echo

    exit 2

fi
