# Docker e2e test for cause-aware requeue limits

Self-contained 2-node Slurm cluster that builds from the patched source
and verifies MaxNodeFailRequeue / MaxPreemptRequeue behavior.

## Prerequisites

- Docker Desktop running
- This directory must be inside the Slurm source tree (it builds from `../../`)

## Quick start

```bash
./run.sh
# Builds image, starts cluster, registers QoS, runs smoke test.
# Then run the requeue limits test:
./verify_requeue_limits.sh
```

## What each file does

| File | Purpose |
|---|---|
| `Dockerfile` | Builds Slurm from source (`../../`) on Rocky 9 |
| `docker-compose.yml` | 4-container cluster: slurmctld, slurmdbd, mysql, 2× slurmd (c1, c2) |
| `etc/slurm.conf` | Cluster config with `MaxNodeFailRequeue=2`, `MaxPreemptRequeue=2` |
| `etc/slurmdbd.conf` | DBD config pointing to mysql container |
| `entrypoint.sh` | Container init: starts munge + the appropriate Slurm daemon |
| `munge.key` | Shared MUNGE key for auth across containers |
| `register_cluster.sh` | Creates account `acct1`, QoS `high` (priority 100, preempts) and `low` (priority 10) |
| `run.sh` | One-shot: build → start → register → smoke test |
| `verify_requeue_limits.sh` | **The main test** — 9 scenarios exercising all requeue cause paths |

## What `verify_requeue_limits.sh` tests (9 scenarios)

1. **NODE_FAIL hold**: Submit job on c1, repeatedly `state=DOWN` the node. After 3 node failures (limit=2), job is held with `Reason=node_failure_requeue_limit_exceeded_requeued_held`, `Priority=0`.
2. **NODE_FAIL held state**: Held job shows `REQUEUE_HOLD` state.
3. **Independence**: Node-fail requeue does NOT trigger `WAIT_MAX_REQUEUE` (MaxBatchRequeue path).
4. **PREEMPT hold**: Submit low-QoS victim, preempt with high-QoS job 3 times. After exceeding limit, victim held with `Reason=preemption_requeue_limit_exceeded_requeued_held`.
5. **PREEMPT held state**: Held job shows `REQUEUE_HOLD`, `Priority=0`.
6. **Counter independence**: Preempt counter does not affect node-fail counter.
7. **requeuehold exempt**: `scontrol requeuehold` does NOT count toward preemption budget.
8. **Release resets counters**: `scontrol release` gives fresh allowance — 2 more requeues before re-hold.
9. **Unlimited mode**: `MaxPreemptRequeue=0` means never hold for preemption, even after 4+ preemptions.

## Manual testing

```bash
docker compose exec slurmctld bash

# Submit a requeueable job on node c1
sbatch --parsable -A acct1 --qos=low -w c1 --requeue --exclusive --wrap="sleep 600"

# Wait for RUNNING, then simulate 3 node failures:
scontrol update nodename=c1 state=down reason=test1
sleep 2; scontrol update nodename=c1 state=resume; sleep 10
scontrol update nodename=c1 state=down reason=test2
sleep 2; scontrol update nodename=c1 state=resume; sleep 10
scontrol update nodename=c1 state=down reason=test3

# Job should now be held:
squeue                              # shows REQUEUE_HOLD
scontrol show job <id> | grep Reason  # node_failure_requeue_limit_exceeded_requeued_held
```

## Teardown

```bash
docker compose down -v
```
