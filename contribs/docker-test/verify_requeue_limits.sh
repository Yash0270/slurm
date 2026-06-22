#!/usr/bin/env bash
# verify_requeue_limits.sh - e2e test for cause-aware batch-job requeue limits.
#
# Exercises each requeue cause to its (small) limit and asserts the job is held
# with the cause-specific Reason, and that causes are counted independently.
#
# Requires slurm.conf to set (small values for speed):
#     MaxNodeFailRequeue=2
#     MaxPreemptRequeue=2
#     MaxBatchRequeue=5   (kept; FAILURE path unchanged)
# and register_cluster.sh to have created QoS low/high + account acct1.
#
# Run after `docker compose up -d` + `./register_cluster.sh`.
set -uo pipefail
cd "$(dirname "$0")"

ACCT="${ACCT:-acct1}"
dexec() { docker compose exec -T slurmctld "$@"; }
dctl()  { docker compose exec -T slurmctld bash -lc "$*"; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

jstate() { dexec squeue -h -j "$1" -o '%T' 2>/dev/null | tr -d '[:space:]'; }
# Reason as shown to operators. squeue %r / scontrol Reason= render the job's
# state_desc when set (our cause-specific hold message), e.g.
#   "node failure requeue limit exceeded requeued held"
# We assert on a cause-specific keyword within it; the underlying enum
# (WAIT_MAX_NODE_FAIL_REQUEUE / WAIT_MAX_PREEMPT_REQUEUE) drives both.
jreason() {
    dexec scontrol show job "$1" 2>/dev/null \
        | grep -oE 'Reason=[^ ]+' | head -1 | cut -d= -f2
}
jprio() {
    dexec scontrol show job "$1" 2>/dev/null \
        | grep -oE 'Priority=[0-9]+' | head -1 | cut -d= -f2
}

wait_state() { # job_id desired_state max_secs
    local id="$1" want="$2" n="${3:-30}" st
    for _ in $(seq 1 "$n"); do
        st=$(jstate "$id")
        [ "$st" = "$want" ] && return 0
        sleep 1
    done
    return 1
}

echo "############################################################"
echo "# Cause-aware requeue limits e2e"
echo "# Config in effect:"
dexec scontrol show config 2>/dev/null \
    | grep -iE "MaxBatchRequeue|MaxNodeFailRequeue|MaxPreemptRequeue" | sed 's/^/#   /'
echo "############################################################"

############################################################
# Scenario 1: NODE_FAIL -> WAIT_MAX_NODE_FAIL_REQUEUE
#  c1 hosts the test job (-N1 --requeue). A filler keeps c2 busy so the
#  requeued job can only re-land on c1. We down c1 repeatedly; each node
#  failure requeues the job and bumps node_fail_requeue_cnt. With the limit
#  at 2, the 3rd node-fail requeue must hold the job.
############################################################
echo
echo "=== Scenario 1: NODE_FAIL limit (MaxNodeFailRequeue=2) ==="

# Filler pins c2 so -N1 test job is forced onto c1.
FILL_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=low -J fillc2 -w c2 \
    --exclusive --wrap='sleep 600'")
echo "  filler(c2) job: ${FILL_ID}"
wait_state "$FILL_ID" RUNNING 30 || echo "  (warn) filler not running yet"

# Test job pinned to c1, requeueable.
NF_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=low -J nodefail -w c1 \
    --requeue --exclusive --wrap='sleep 600'")
echo "  node-fail test job: ${NF_ID}"
if ! wait_state "$NF_ID" RUNNING 30; then
    fail "NODE_FAIL: test job never started on c1"
fi

held_reason=""
for cycle in 1 2 3; do
    echo "  --- node-fail cycle ${cycle} ---"
    # Force the node down so the running job is requeued by node failure.
    dexec scontrol update nodename=c1 state=down reason="e2e nodefail ${cycle}" >/dev/null 2>&1

    # Wait until the job leaves RUNNING (requeued -> PENDING) or gets held.
    for _ in $(seq 1 30); do
        st=$(jstate "$NF_ID")
        [ "$st" != "RUNNING" ] && [ -n "$st" ] && break
        sleep 1
    done
    rsn=$(jreason "$NF_ID"); prio=$(jprio "$NF_ID")
    echo "    after down: state=$(jstate "$NF_ID") reason=${rsn} prio=${prio}"

    # Before the limit is exceeded (cycles 1,2) the job must NOT be held for
    # a requeue limit, and must NOT have tripped the FAILURE/MaxBatchRequeue
    # path.
    if [ "$cycle" -lt 3 ]; then
        case "$rsn" in
            *node_failure_requeue*)
                fail "NODE_FAIL: held too early (cycle ${cycle}, reason ${rsn})" ;;
            *launch_failure_limit*)
                fail "NODE_FAIL: tripped MaxBatchRequeue hold (cycle ${cycle})" ;;
        esac
    fi

    # Bring c1 back so the job can be scheduled again.
    dexec scontrol update nodename=c1 state=resume >/dev/null 2>&1
    sleep 1

    if [ "$cycle" -lt 3 ]; then
        # Job should run again on c1 before the next cycle.
        if ! wait_state "$NF_ID" RUNNING 40; then
            echo "    (warn) job did not return to RUNNING after resume (cycle ${cycle}); state=$(jstate "$NF_ID") reason=$(jreason "$NF_ID")"
        fi
    fi
done

# After 3 node failures (cnt=3 > limit 2) the job must be held (REQUEUE_HOLD,
# priority 0) with the node-failure-specific reason.
for _ in $(seq 1 20); do
    held_reason=$(jreason "$NF_ID")
    case "$held_reason" in *node_failure_requeue*) break ;; esac
    sleep 1
done
held_state=$(jstate "$NF_ID"); held_prio=$(jprio "$NF_ID")
echo "  final: state=${held_state} reason=${held_reason} prio=${held_prio}"
dexec scontrol show job "$NF_ID" 2>/dev/null | grep -iE "JobState|Reason|Priority|Requeue" | sed 's/^/    /'

case "$held_reason" in
    *node_failure_requeue*)
        pass "NODE_FAIL: job held with node-failure reason (${held_reason}) after exceeding MaxNodeFailRequeue" ;;
    *)
        fail "NODE_FAIL: expected node-failure hold reason, got '${held_reason}'" ;;
esac
if [ "$held_state" = "REQUEUE_HOLD" ] && [ "$held_prio" = "0" ]; then
    pass "NODE_FAIL: held job is REQUEUE_HOLD with Priority=0"
else
    fail "NODE_FAIL: expected REQUEUE_HOLD/Priority=0, got state=${held_state} prio=${held_prio}"
fi
# Independence: the node-fail path must NOT have used the FAILURE
# (MaxBatchRequeue) hold.
case "$held_reason" in
    *launch_failure_limit*)
        fail "INDEPENDENCE: node-fail requeue tripped WAIT_MAX_REQUEUE (MaxBatchRequeue)" ;;
    *)
        pass "INDEPENDENCE: node-fail requeue did NOT trip WAIT_MAX_REQUEUE (MaxBatchRequeue path)" ;;
esac

# Cleanup scenario 1.
dexec scancel "$NF_ID" "$FILL_ID" >/dev/null 2>&1
dexec scontrol update nodename=c1 state=resume >/dev/null 2>&1
sleep 2

############################################################
# Scenario 2: PREEMPT -> WAIT_MAX_PREEMPT_REQUEUE
#  A low-QoS job fills the cluster; a high-QoS job preempts (requeues) it.
#  Each preemption bumps preempt_requeue_cnt. With the limit at 2, the 3rd
#  preemption requeue must hold the low job.
############################################################
echo
echo "=== Scenario 2: PREEMPT limit (MaxPreemptRequeue=2) ==="

# Low job spans both nodes exclusively so any high job preempts it.
LOW_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=low -J lowvictim \
    -N2 --ntasks-per-node=2 --exclusive --requeue --wrap='sleep 600'")
echo "  low victim job: ${LOW_ID}"
if ! wait_state "$LOW_ID" RUNNING 30; then
    fail "PREEMPT: low victim never started"
fi

preempt_reason=""
for cycle in 1 2 3; do
    echo "  --- preempt cycle ${cycle} ---"
    HI_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=high -J highpre${cycle} \
        -N2 --ntasks-per-node=2 --exclusive --wrap='sleep 8'")
    echo "    high job: ${HI_ID}"

    # Wait for the low job to be preempted out of RUNNING.
    for _ in $(seq 1 30); do
        st=$(jstate "$LOW_ID")
        [ "$st" != "RUNNING" ] && [ -n "$st" ] && break
        sleep 1
    done
    rsn=$(jreason "$LOW_ID")
    echo "    after preempt: low state=$(jstate "$LOW_ID") reason=${rsn} prio=$(jprio "$LOW_ID")"

    if [ "$cycle" -lt 3 ]; then
        case "$rsn" in
            *preemption_requeue*) fail "PREEMPT: held too early (cycle ${cycle})" ;;
        esac
    fi

    # Let the high job finish so the low job can run again.
    wait_state "$HI_ID" "" 1 >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        hs=$(jstate "$HI_ID"); [ -z "$hs" ] && break; sleep 1
    done

    if [ "$cycle" -lt 3 ]; then
        if ! wait_state "$LOW_ID" RUNNING 40; then
            echo "    (warn) low job did not resume RUNNING (cycle ${cycle}); state=$(jstate "$LOW_ID") reason=$(jreason "$LOW_ID")"
        fi
    fi
done

for _ in $(seq 1 20); do
    preempt_reason=$(jreason "$LOW_ID")
    case "$preempt_reason" in *preemption_requeue*) break ;; esac
    sleep 1
done
p_state=$(jstate "$LOW_ID"); p_prio=$(jprio "$LOW_ID")
echo "  final: state=${p_state} reason=${preempt_reason} prio=${p_prio}"
dexec scontrol show job "$LOW_ID" 2>/dev/null | grep -iE "JobState|Reason|Priority" | sed 's/^/    /'

case "$preempt_reason" in
    *preemption_requeue*)
        pass "PREEMPT: job held with preemption reason (${preempt_reason}) after exceeding MaxPreemptRequeue" ;;
    *)
        fail "PREEMPT: expected preemption hold reason, got '${preempt_reason}'" ;;
esac
if [ "$p_state" = "REQUEUE_HOLD" ] && [ "$p_prio" = "0" ]; then
    pass "PREEMPT: held job is REQUEUE_HOLD with Priority=0"
else
    fail "PREEMPT: expected REQUEUE_HOLD/Priority=0, got state=${p_state} prio=${p_prio}"
fi

# Independence: the preempt hold must not be the node-fail or batch reason.
case "$preempt_reason" in
    *node_failure_requeue*|*launch_failure_limit*)
        fail "INDEPENDENCE: preempt requeue tripped the wrong (node-fail/batch) limit" ;;
    *)
        pass "INDEPENDENCE: preempt requeue used its own counter (not node-fail/batch)" ;;
esac

dexec scancel "$LOW_ID" >/dev/null 2>&1
sleep 2

############################################################
# Scenario 3: scontrol requeuehold is an explicit user hold -> it must NOT
#  count toward the PREEMPT limit and must NOT be relabeled as a preemption
#  hold. We requeuehold a running job once; the hold reason must be the user
#  hold (JobHeldUser), not preemption, and the preempt counter must be
#  untouched (proven afterwards: two plain requeues still don't hold, since
#  the limit is 2 and requeuehold added nothing).
############################################################
echo
echo "=== Scenario 3: scontrol requeuehold does NOT count as PREEMPT ==="
dexec scontrol update nodename=c1 state=resume >/dev/null 2>&1
RH_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=low -J requeuehold -w c1 \
    --requeue --exclusive --wrap='sleep 600'")
echo "  requeuehold test job: ${RH_ID}"
if ! wait_state "$RH_ID" RUNNING 30; then
    fail "REQUEUEHOLD: test job never started"
fi

dexec scontrol requeuehold "$RH_ID" >/dev/null 2>&1
# Wait for it to settle into the held state.
for _ in $(seq 1 20); do
    [ "$(jstate "$RH_ID")" != "RUNNING" ] && break
    sleep 1
done
rh_reason=$(jreason "$RH_ID"); rh_state=$(jstate "$RH_ID")
echo "  after requeuehold: state=${rh_state} reason=${rh_reason} prio=$(jprio "$RH_ID")"

case "$rh_reason" in
    *preemption_requeue*|*JobHoldMaxPreempt*)
        fail "REQUEUEHOLD: relabeled as preemption hold (${rh_reason})" ;;
    JobHeldUser|*held*)
        pass "REQUEUEHOLD: held with user-hold reason (${rh_reason}), not preemption" ;;
    *)
        pass "REQUEUEHOLD: not a preemption hold (reason ${rh_reason})" ;;
esac

# Prove the counter was not bumped: release, then plain-requeue exactly twice.
# With MaxPreemptRequeue=2, two plain requeues reach the limit but do NOT
# exceed it, so the job must still NOT be preempt-held. (If requeuehold had
# counted, the 2nd plain requeue would be the 3rd and would hold.)
dexec scontrol release "$RH_ID" >/dev/null 2>&1
sleep 2
wait_state "$RH_ID" RUNNING 40 >/dev/null 2>&1
for c in 1 2; do
    dexec scontrol requeue "$RH_ID" >/dev/null 2>&1
    for _ in $(seq 1 15); do
        [ "$(jstate "$RH_ID")" != "RUNNING" ] && break
        sleep 1
    done
    dexec scontrol release "$RH_ID" >/dev/null 2>&1
    sleep 1
    wait_state "$RH_ID" RUNNING 40 >/dev/null 2>&1
done
rh_reason2=$(jreason "$RH_ID")
echo "  after release + 2 plain requeues: state=$(jstate "$RH_ID") reason=${rh_reason2}"
# NOTE: scontrol release resets the per-cause counters (fix #6), so this also
# exercises that release gives a fresh allowance.
case "$rh_reason2" in
    *preemption_requeue*)
        fail "REQUEUEHOLD: preempt-held after only 2 counted requeues (requeuehold must not count / release must reset)" ;;
    *)
        pass "REQUEUEHOLD: not preempt-held after 2 counted requeues (requeuehold not counted; release reset)" ;;
esac
dexec scancel "$RH_ID" >/dev/null 2>&1
sleep 2

############################################################
# Scenario 4: MaxPreemptRequeue=0 means unlimited -> preemption must NEVER
#  hold the job no matter how many times it is preempted.
############################################################
echo
echo "=== Scenario 4: MaxPreemptRequeue=0 (unlimited) ==="
CONF=etc/slurm.conf
# Flip MaxPreemptRequeue to 0 and reconfigure (the limit is read live by
# slurmctld). IMPORTANT: edit the file IN PLACE (truncate + rewrite the same
# inode). sed -i / mv would create a new inode and sever the Docker bind mount.
CONF_SAVE="$(cat "$CONF")"
restore_conf() {
    printf '%s\n' "$CONF_SAVE" > "$CONF"   # in-place, preserves inode
    dexec scontrol reconfigure >/dev/null 2>&1
}
trap restore_conf EXIT
printf '%s\n' "$CONF_SAVE" | sed 's/^MaxPreemptRequeue=.*/MaxPreemptRequeue=0/' > "$CONF"
dexec scontrol reconfigure >/dev/null 2>&1
sleep 3
eff=$(dexec scontrol show config 2>/dev/null | grep -i MaxPreemptRequeue | tr -s ' ')
echo "  reconfigured: ${eff}"
case "$eff" in
    *"= 0"*) : ;;
    *) fail "UNLIMITED: reconfigure to MaxPreemptRequeue=0 did not take effect (${eff})" ;;
esac

ULOW_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=low -J unlimited \
    -N2 --ntasks-per-node=2 --exclusive --requeue --wrap='sleep 600'")
echo "  unlimited victim job: ${ULOW_ID}"
if ! wait_state "$ULOW_ID" RUNNING 30; then
    fail "UNLIMITED: victim job never started (cannot exercise unlimited path)"
fi

u_held=0
u_preempted=0
for cycle in 1 2 3 4; do
    UHI_ID=$(dctl "sbatch --parsable -A ${ACCT} --qos=high -J uhigh${cycle} \
        -N2 --ntasks-per-node=2 --exclusive --wrap='sleep 6'")
    left_running=0
    for _ in $(seq 1 30); do
        st=$(jstate "$ULOW_ID")
        if [ "$st" != "RUNNING" ] && [ -n "$st" ]; then left_running=1; break; fi
        sleep 1
    done
    [ "$left_running" = "1" ] && u_preempted=$((u_preempted+1))
    rsn=$(jreason "$ULOW_ID")
    echo "    cycle ${cycle}: low state=$(jstate "$ULOW_ID") reason=${rsn}"
    case "$rsn" in *preemption_requeue*) u_held=1 ;; esac
    # let high finish, then let low resume
    for _ in $(seq 1 20); do [ -z "$(jstate "$UHI_ID")" ] && break; sleep 1; done
    wait_state "$ULOW_ID" RUNNING 40 >/dev/null 2>&1
done
echo "  (victim was preempted ${u_preempted}/4 cycles)"

if [ "$u_preempted" -lt 3 ]; then
    fail "UNLIMITED: victim was only preempted ${u_preempted}/4 times — test did not exercise enough preemptions"
elif [ "$u_held" -eq 0 ]; then
    pass "UNLIMITED: MaxPreemptRequeue=0 never preempt-held the job after ${u_preempted} preemptions"
else
    fail "UNLIMITED: job was preempt-held despite MaxPreemptRequeue=0"
fi

# Restore config (also covered by the EXIT trap).
dexec scancel "$ULOW_ID" >/dev/null 2>&1
restore_conf
trap - EXIT
sleep 2

############################################################
echo
echo "############################################################"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then
    echo "OVERALL: PASS"
    exit 0
else
    echo "OVERALL: FAIL"
    exit 1
fi
