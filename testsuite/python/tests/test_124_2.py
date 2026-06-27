############################################################################
# Copyright (C) SchedMD LLC.
############################################################################
# Multi-QOS per-user/per-account TRES usage must stay attributed to the QOS
# member a running job was dispatched under, across a state reload.
#
# Regression test for: a job submitted with multiple QOS (--qos=a,b) that is
# forced to start under a NON-highest-priority member gets re-attributed to the
# highest-priority member on `scontrol reconfigure` (state reload), inflating
# that member's per-user gres/gpu usage and spuriously triggering
# QOSMaxGRESPerUser.
############################################################################
import atf
import re
import pytest

# QOS / sizing. 'high' is the highest priority member and caps per-user gpu at
# GPU_CAP; a 'high' blocker fills that cap so the --qos=low,high victim is
# forced onto 'low' (the non-head member).
GPU_PER_NODE = 4
GPU_CAP = 2  # high MaxTRESPerUser=gres/gpu
BLOCK_GPUS = 2  # fills high's per-user cap
VICTIM_GPUS = 2  # cannot fit under high -> runs under low


@pytest.fixture(scope="module", autouse=True)
def setup():
    atf.require_auto_config("manually creates QOS, per-user GRES limits and a multi-QOS job")
    atf.require_config_parameter("SelectType", "select/cons_tres")
    atf.require_config_parameter("SelectTypeParameters", "CR_CPU")
    atf.require_config_parameter_includes("GresTypes", "gpu")
    for i in range(GPU_PER_NODE):
        atf.require_tty(i)
    atf.require_config_parameter(
        "Name", {"gpu": {"File": f"/dev/tty[0-{GPU_PER_NODE - 1}]"}}, source="gres"
    )
    atf.require_nodes(1, [("Gres", f"gpu:{GPU_PER_NODE}"), ("CPUs", GPU_PER_NODE)])
    atf.require_accounting(modify=True)
    atf.require_config_parameter_includes("AccountingStorageTRES", "gres/gpu")
    atf.require_config_parameter_includes("AccountingStorageEnforce", "associations")
    atf.require_config_parameter_includes("AccountingStorageEnforce", "qos")
    atf.require_config_parameter_includes("AccountingStorageEnforce", "limits")
    atf.require_slurm_running()


@pytest.fixture(scope="module", autouse=True)
def qos_and_account(setup):
    su = atf.properties["slurm-user"]
    user = atf.get_user_name()
    atf.run_command("sacctmgr -i add qos low Priority=1", user=su, fatal=True)
    atf.run_command(
        f"sacctmgr -i add qos high Priority=100 MaxTRESPerUser=gres/gpu={GPU_CAP}",
        user=su,
        fatal=True,
    )
    atf.run_command("sacctmgr -i add account multiqos", user=su, fatal=True)
    atf.run_command(
        f"sacctmgr -i add user {user} DefaultAccount=multiqos account=multiqos "
        "qos=normal,low,high",
        user=su,
        fatal=True,
    )
    # Make sure the controller has the QOS/assoc before we submit.
    atf.repeat_until(
        lambda: atf.run_command_output("scontrol show assoc_mgr flags=qos", user=su),
        lambda out: re.search(r"QOS=low\(", out) and re.search(r"QOS=high\(", out),
        fatal=True,
    )
    yield
    atf.cancel_all_jobs(quiet=True)
    atf.run_command(f"sacctmgr -i modify user {user} set qos=normal", user=su, quiet=True)
    atf.run_command("sacctmgr -i remove account multiqos", user=su, quiet=True)
    atf.run_command("sacctmgr -i remove qos low high", user=su, quiet=True)


def used_gpu_for_qos(qos_name):
    """Per-user gres/gpu USED for our user under the named QOS.

    `scontrol -o show assoc_mgr flags=qos` prints one QOS record per line; each
    per-user sub-entry looks like:  <user>(<uid>)={ ... MaxTRESPU=...gres/gpu=<lim>(<used>) ... }
    """
    su = atf.properties["slurm-user"]
    user = atf.get_user_name()
    out = atf.run_command_output(
        "scontrol -o show assoc_mgr flags=qos", user=su, fatal=True
    )
    for line in out.splitlines():
        m = re.search(r"QOS=([^\s(]+)\(", line)
        if not m or m.group(1) != qos_name:
            continue
        um = re.search(
            re.escape(user)
            + r"\(\d+\)=\{[^}]*MaxTRESPU=[^}]*gres/gpu=(?:N|\d+)\((\d+)\)",
            line,
        )
        if um:
            return int(um.group(1))
    return 0


def test_multi_qos_gres_usage_stable_across_reconfigure():
    """A running --qos=low,high job started under 'low' must stay charged to
    'low' (not the highest-priority 'high') after scontrol reconfigure."""
    su = atf.properties["slurm-user"]

    # 1) Blocker fills high's per-user gpu cap so the victim cannot use high.
    blocker = atf.submit_job_sbatch(
        f"--account=multiqos --qos=high --gres=gpu:{BLOCK_GPUS} -N1 "
        "--wrap='sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(blocker, "RUNNING", fatal=True)

    # 2) Multi-QOS victim is forced onto the non-head member 'low'.
    victim = atf.submit_job_sbatch(
        f"--account=multiqos --qos=low,high --gres=gpu:{VICTIM_GPUS} -N1 "
        "--wrap='sleep 600'",
        fatal=True,
    )
    atf.wait_for_job_state(victim, "RUNNING", fatal=True)
    assert (
        atf.get_job_parameter(victim, "QOS") == "low"
    ), "victim should be forced onto the non-head QOS 'low'"

    # 3) Baseline attribution is correct: victim on low, blocker on high.
    assert used_gpu_for_qos("low") == VICTIM_GPUS
    assert used_gpu_for_qos("high") == BLOCK_GPUS

    # 4) State reload. Before the fix this re-attributes the running victim to
    #    the highest-priority member 'high'.
    assert (
        atf.run_command_exit("scontrol reconfigure", user=su, fatal=True) == 0
    )

    # 5) Attribution must be unchanged: victim stays on 'low', 'high' is not
    #    inflated by the victim's GPUs.
    assert (
        used_gpu_for_qos("low") == VICTIM_GPUS
    ), "running victim was re-attributed off 'low' on reload (regression)"
    assert (
        used_gpu_for_qos("high") == BLOCK_GPUS
    ), "'high' per-user gres/gpu was inflated on reload (regression)"
    assert (
        atf.get_job_parameter(victim, "QOS") == "low"
    ), "victim QOS flipped to 'high' on reload (regression)"
