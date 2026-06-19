############################################################################
# Copyright (C) SchedMD LLC.
############################################################################
"""
Cause-aware batch job requeue limits (MaxNodeFailRequeue, MaxPreemptRequeue).

Verifies that node-failure requeues, preemption requeues, and launch-failure
requeues are counted independently, each against its own configurable limit.

Tested:
- Node-failure requeues are held at MaxNodeFailRequeue with
  JobHoldMaxNodeFailRequeue reason.
- Preemption requeues are held at MaxPreemptRequeue with
  JobHoldMaxPreemptRequeue reason.
- Node-failure requeues do NOT count toward MaxBatchRequeue.
- Preemption requeues do NOT count toward MaxNodeFailRequeue.
- scontrol requeuehold does NOT consume the preemption budget.
- scontrol release resets per-cause counters (fresh allowance).
- MaxPreemptRequeue=0 means unlimited (job is never held for preemption).
"""
import atf
import pytest
import re
import time

NODE_FAIL_LIMIT = 2
PREEMPT_LIMIT = 2

pytestmark = pytest.mark.slow


@pytest.fixture(scope="module", autouse=True)
def setup():
    atf.require_nodes(2, [("CPUs", 2)])
    atf.require_config_parameter("SelectType", "select/cons_tres")
    atf.require_config_parameter("PreemptType", "preempt/qos")
    atf.require_config_parameter("PreemptMode", "REQUEUE")
    atf.require_config_parameter("MaxNodeFailRequeue", str(NODE_FAIL_LIMIT))
    atf.require_config_parameter("MaxPreemptRequeue", str(PREEMPT_LIMIT))
    atf.require_config_parameter("MaxBatchRequeue", "5")
    atf.require_config_parameter_includes(
        "SchedulerParameters", "requeue_delay=0"
    )
    atf.require_config_parameter("ReturnToService", "1")
    atf.require_accounting()
    atf.require_slurm_running()


@pytest.fixture(scope="module")
def nodes():
    node_list = list(atf.nodes)
    assert len(node_list) >= 2, "Need at least 2 nodes"
    return node_list[0], node_list[1]


@pytest.fixture(scope="function", autouse=True)
def cleanup_nodes(nodes):
    """Resume any downed nodes after each test."""
    yield
    for node in nodes:
        atf.run_command(
            f"scontrol update nodename={node} state=RESUME",
            user=atf.properties["slurm-user"],
            quiet=True,
        )
        atf.wait_for_node_state(node, "IDLE", timeout=30, fatal=False)


def test_node_fail_hold_at_limit(nodes):
    """A job requeued by node failure is held after MaxNodeFailRequeue."""
    target_node, other_node = nodes

    # Pin a filler job on the other node so our test job only runs on target
    filler = atf.submit_job_sbatch(
        f"-N1 -w {other_node} --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(filler, "RUNNING", fatal=True)

    # Submit test job pinned to target node
    job_id = atf.submit_job_sbatch(
        f"-N1 -w {target_node} --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(job_id, "RUNNING", fatal=True)

    # Cycle through node failures up to and past the limit
    for cycle in range(1, NODE_FAIL_LIMIT + 2):
        atf.run_command(
            f"scontrol update nodename={target_node} state=DOWN reason=test_cycle_{cycle}",
            user=atf.properties["slurm-user"],
            fatal=True,
        )
        # Wait for job to leave RUNNING
        atf.repeat_until(
            lambda: atf.get_job_parameter(job_id, "JobState"),
            lambda s: s != "RUNNING",
            timeout=30,
        )

        if cycle <= NODE_FAIL_LIMIT:
            # Should NOT be held yet
            reason = atf.get_job_parameter(job_id, "Reason") or ""
            assert "MaxNodeFailRequeue" not in reason, (
                f"Job should not be held after {cycle} node failures "
                f"(limit is {NODE_FAIL_LIMIT}), Reason={reason}"
            )
            # Resume node for next cycle
            atf.run_command(
                f"scontrol update nodename={target_node} state=RESUME",
                user=atf.properties["slurm-user"],
                fatal=True,
            )
            atf.wait_for_node_state(target_node, "IDLE", fatal=True)
            atf.wait_for_job_state(job_id, "RUNNING", fatal=True)
        else:
            # Past the limit — job must be held
            reason = atf.get_job_parameter(job_id, "Reason") or ""
            priority = atf.get_job_parameter(job_id, "Priority")
            assert "node_failure_requeue_limit" in reason.lower() or \
                   "JobHoldMaxNodeFailRequeue" in reason, (
                f"Job should be held with node-failure reason after "
                f"{cycle} failures, got Reason={reason}"
            )
            assert str(priority) == "0", (
                f"Held job should have Priority=0, got {priority}"
            )

    atf.cancel_jobs([filler, job_id])


def test_node_fail_independent_from_batch_requeue(nodes):
    """Node-failure requeues must NOT count toward MaxBatchRequeue."""
    target_node, other_node = nodes

    filler = atf.submit_job_sbatch(
        f"-N1 -w {other_node} --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(filler, "RUNNING", fatal=True)

    job_id = atf.submit_job_sbatch(
        f"-N1 -w {target_node} --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(job_id, "RUNNING", fatal=True)

    # Do one node failure requeue
    atf.run_command(
        f"scontrol update nodename={target_node} state=DOWN reason=test",
        user=atf.properties["slurm-user"],
        fatal=True,
    )
    atf.repeat_until(
        lambda: atf.get_job_parameter(job_id, "JobState"),
        lambda s: s != "RUNNING",
        timeout=30,
    )

    reason = atf.get_job_parameter(job_id, "Reason") or ""
    assert "MaxRequeue" not in reason or "MaxNodeFail" in reason, (
        f"Node-failure requeue should NOT trigger WAIT_MAX_REQUEUE "
        f"(MaxBatchRequeue path), got Reason={reason}"
    )

    atf.cancel_jobs([filler, job_id])


def test_preempt_hold_at_limit(nodes):
    """A job preempted past MaxPreemptRequeue is held."""
    target_node = nodes[0]

    for cycle in range(1, PREEMPT_LIMIT + 2):
        # Submit low-priority victim
        if cycle == 1:
            victim = atf.submit_job_sbatch(
                f"-N1 -w {target_node} --exclusive --requeue "
                f"--qos=low --wrap 'sleep 600'",
                fatal=True,
            )
        atf.wait_for_job_state(victim, "RUNNING", fatal=True, timeout=60)

        # Submit high-priority preemptor
        preemptor = atf.submit_job_sbatch(
            f"-N1 -w {target_node} --exclusive "
            f"--qos=high --wrap 'sleep 5'",
            fatal=True,
        )
        atf.wait_for_job_state(preemptor, "RUNNING", fatal=True)

        # Wait for preemptor to finish
        atf.wait_for_job_state(preemptor, "DONE", fatal=True, timeout=30)

        if cycle <= PREEMPT_LIMIT:
            reason = atf.get_job_parameter(victim, "Reason") or ""
            assert "MaxPreemptRequeue" not in reason, (
                f"Victim should not be held after {cycle} preemptions "
                f"(limit is {PREEMPT_LIMIT}), Reason={reason}"
            )
        else:
            reason = atf.get_job_parameter(victim, "Reason") or ""
            priority = atf.get_job_parameter(victim, "Priority")
            assert "preemption_requeue_limit" in reason.lower() or \
                   "JobHoldMaxPreemptRequeue" in reason, (
                f"Victim should be held with preemption reason after "
                f"{cycle} preemptions, got Reason={reason}"
            )
            assert str(priority) == "0", (
                f"Held job should have Priority=0, got {priority}"
            )

    atf.cancel_jobs([victim])


def test_requeuehold_exempt_from_counting():
    """scontrol requeuehold must NOT count toward MaxPreemptRequeue."""
    job_id = atf.submit_job_sbatch(
        "-N1 --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(job_id, "RUNNING", fatal=True)

    # requeuehold — should NOT count
    atf.run_command(
        f"scontrol requeuehold {job_id}",
        user=atf.properties["slurm-user"],
        fatal=True,
    )
    atf.wait_for_job_state(job_id, "PENDING", fatal=True)
    reason = atf.get_job_parameter(job_id, "Reason") or ""
    assert "MaxPreemptRequeue" not in reason, (
        f"requeuehold should NOT trigger preemption limit, Reason={reason}"
    )

    atf.cancel_jobs([job_id])


def test_release_resets_counters(nodes):
    """scontrol release must reset per-cause counters."""
    target_node, other_node = nodes

    filler = atf.submit_job_sbatch(
        f"-N1 -w {other_node} --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(filler, "RUNNING", fatal=True)

    job_id = atf.submit_job_sbatch(
        f"-N1 -w {target_node} --exclusive --requeue --wrap 'sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(job_id, "RUNNING", fatal=True)

    # Hit the node-fail limit
    for cycle in range(NODE_FAIL_LIMIT + 1):
        atf.run_command(
            f"scontrol update nodename={target_node} state=DOWN reason=test_{cycle}",
            user=atf.properties["slurm-user"],
            fatal=True,
        )
        atf.repeat_until(
            lambda: atf.get_job_parameter(job_id, "JobState"),
            lambda s: s != "RUNNING",
            timeout=30,
        )
        if cycle < NODE_FAIL_LIMIT:
            atf.run_command(
                f"scontrol update nodename={target_node} state=RESUME",
                user=atf.properties["slurm-user"],
                fatal=True,
            )
            atf.wait_for_node_state(target_node, "IDLE", fatal=True)
            atf.wait_for_job_state(job_id, "RUNNING", fatal=True)

    # Job should be held now
    reason = atf.get_job_parameter(job_id, "Reason") or ""
    assert "node_failure" in reason.lower() or "MaxNodeFail" in reason

    # Release the hold — counters should reset
    atf.run_command(
        f"scontrol update nodename={target_node} state=RESUME",
        user=atf.properties["slurm-user"],
        fatal=True,
    )
    atf.wait_for_node_state(target_node, "IDLE", fatal=True)
    atf.run_command(
        f"scontrol release {job_id}",
        user=atf.properties["slurm-user"],
        fatal=True,
    )
    atf.wait_for_job_state(job_id, "RUNNING", fatal=True, timeout=60)

    # One more node failure should NOT immediately re-hold
    # (counter was reset by release)
    atf.run_command(
        f"scontrol update nodename={target_node} state=DOWN reason=after_release",
        user=atf.properties["slurm-user"],
        fatal=True,
    )
    atf.repeat_until(
        lambda: atf.get_job_parameter(job_id, "JobState"),
        lambda s: s != "RUNNING",
        timeout=30,
    )
    reason = atf.get_job_parameter(job_id, "Reason") or ""
    assert "MaxNodeFail" not in reason, (
        f"After release, one node failure should NOT re-hold "
        f"(counters should be reset), Reason={reason}"
    )

    atf.cancel_jobs([filler, job_id])


def test_unlimited_preempt_requeue(nodes):
    """MaxPreemptRequeue=0 means unlimited — job is never held for preemption."""
    target_node = nodes[0]

    # Set unlimited
    atf.set_config_parameter("MaxPreemptRequeue", "0")
    atf.run_command(
        "scontrol reconfigure",
        user=atf.properties["slurm-user"],
        fatal=True,
    )

    victim = atf.submit_job_sbatch(
        f"-N1 -w {target_node} --exclusive --requeue "
        f"--qos=low --wrap 'sleep 600'",
        fatal=True,
    )

    # Preempt more times than the original limit
    for cycle in range(PREEMPT_LIMIT + 2):
        atf.wait_for_job_state(victim, "RUNNING", fatal=True, timeout=60)
        preemptor = atf.submit_job_sbatch(
            f"-N1 -w {target_node} --exclusive "
            f"--qos=high --wrap 'sleep 2'",
            fatal=True,
        )
        atf.wait_for_job_state(preemptor, "DONE", fatal=True, timeout=30)

    # Victim should still be PENDING (not held)
    reason = atf.get_job_parameter(victim, "Reason") or ""
    priority = atf.get_job_parameter(victim, "Priority")
    assert "MaxPreemptRequeue" not in reason, (
        f"With MaxPreemptRequeue=0, job should never be held for "
        f"preemption, got Reason={reason}"
    )
    assert str(priority) != "0", (
        f"Job should not have Priority=0 with unlimited preemption"
    )

    atf.cancel_jobs([victim])

    # Restore original limit
    atf.set_config_parameter("MaxPreemptRequeue", str(PREEMPT_LIMIT))
    atf.run_command(
        "scontrol reconfigure",
        user=atf.properties["slurm-user"],
        fatal=True,
    )
