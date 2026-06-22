#!/usr/bin/env bash
# register_cluster.sh - one-time accounting + QoS setup for preemption tests.
# Run from the host AFTER `docker compose up -d` and after slurmctld is up:
#     ./register_cluster.sh
# It execs sacctmgr inside the slurmctld container.
set -euo pipefail
cd "$(dirname "$0")"   # so `docker compose` finds docker-compose.yml

CTLD="${CTLD_CONTAINER:-slurm-slurmctld}"
CLUSTER="${CLUSTER_NAME:-cluster}"
ACCT="${ACCT:-acct1}"
TESTUSER="${TESTUSER:-root}"

dexec() { docker compose exec -T slurmctld "$@"; }

echo "[register] waiting for slurmdbd to answer sacctmgr ..."
for i in $(seq 1 30); do
    if dexec sacctmgr -i show cluster >/dev/null 2>&1; then break; fi
    sleep 2
done

echo "[register] ensuring cluster '${CLUSTER}' is registered"
dexec sacctmgr -i add cluster "${CLUSTER}" 2>/dev/null || true

echo "[register] creating QoS: low (priority=1)"
dexec sacctmgr -i add qos low set priority=1 2>/dev/null || true

echo "[register] creating QoS: high (priority=100, preempt=low, PreemptMode=requeue)"
dexec sacctmgr -i add qos high set priority=100 preempt=low PreemptMode=requeue 2>/dev/null || true
# Make sure the preempt relationship is set even if the qos already existed.
dexec sacctmgr -i modify qos high set priority=100 preempt=low PreemptMode=requeue 2>/dev/null || true

echo "[register] creating account '${ACCT}' (QoS low,high allowed)"
dexec sacctmgr -i add account "${ACCT}" Description="preemption test" Organization=test 2>/dev/null || true
dexec sacctmgr -i modify account "${ACCT}" set qos=low,high defaultqos=low 2>/dev/null || true

echo "[register] adding user '${TESTUSER}' to account '${ACCT}' with QoS low,high"
dexec sacctmgr -i add user "${TESTUSER}" account="${ACCT}" 2>/dev/null || true
dexec sacctmgr -i modify user "${TESTUSER}" set qos=low,high defaultqos=low 2>/dev/null || true

echo
echo "[register] === QoS table ==="
dexec sacctmgr -n show qos format=name,priority,preempt,preemptmode
echo
echo "[register] === associations ==="
dexec sacctmgr -n show assoc format=cluster,account,user,qos,defaultqos
echo
echo "[register] done."
