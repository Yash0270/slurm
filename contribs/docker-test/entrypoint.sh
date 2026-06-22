#!/usr/bin/env bash
# Role-selecting entrypoint for the SLURM test cluster.
# Usage: entrypoint.sh <slurmdbd|slurmctld|slurmd>
set -euo pipefail

ROLE="${1:-}"

log() { echo "[entrypoint:${ROLE:-?}] $*"; }

# ---------------------------------------------------------------------------
# munged - required by every SLURM daemon for auth.
# ---------------------------------------------------------------------------
start_munge() {
    mkdir -p /var/run/munge /var/log/munge /var/lib/munge
    chown -R munge:munge /var/run/munge /var/log/munge /var/lib/munge /etc/munge
    chmod 0400 /etc/munge/munge.key
    chmod 0700 /etc/munge /var/lib/munge
    log "starting munged"
    gosu munge /usr/sbin/munged --force
    # Wait until munge answers.
    for i in $(seq 1 10); do
        if munge -n >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    log "WARNING: munge did not become ready in time"
}

# ---------------------------------------------------------------------------
# Wait for a TCP host:port to accept connections (pure bash, no nc needed).
# ---------------------------------------------------------------------------
wait_for_port() {
    local host="$1" port="$2" name="${3:-$1:$2}" tries="${4:-60}"
    log "waiting for ${name} (${host}:${port})"
    for i in $(seq 1 "$tries"); do
        if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
            log "${name} is up"
            return 0
        fi
        sleep 2
    done
    log "ERROR: timed out waiting for ${name}"
    return 1
}

start_munge

case "$ROLE" in
    slurmdbd)
        wait_for_port "${DBHOST:-mysql}" 3306 "mariadb"
        # slurmdbd refuses to start unless slurmdbd.conf is mode 0600 owned by
        # SlurmUser. The conf is bind-mounted read-only at slurmdbd.conf.src, so
        # copy it to the real (writable, non-mounted) path and fix perms here.
        if [ -f /etc/slurm/slurmdbd.conf.src ]; then
            cp /etc/slurm/slurmdbd.conf.src /etc/slurm/slurmdbd.conf
        fi
        chown slurm:slurm /etc/slurm/slurmdbd.conf
        chmod 0600 /etc/slurm/slurmdbd.conf
        mkdir -p /var/log/slurm /var/run/slurm
        chown -R slurm:slurm /var/log/slurm /var/run/slurm
        log "starting slurmdbd"
        exec gosu slurm /usr/local/sbin/slurmdbd -D -vvv
        ;;

    slurmctld)
        wait_for_port "${DBDHOST:-slurmdbd}" 6819 "slurmdbd"
        mkdir -p /var/spool/slurmctld /var/log/slurm /var/run/slurm
        chown -R slurm:slurm /var/spool/slurmctld /var/log/slurm /var/run/slurm
        log "starting slurmctld"
        exec gosu slurm /usr/local/sbin/slurmctld -D -vvv
        ;;

    slurmd)
        wait_for_port "${CTLDHOST:-slurmctld}" 6817 "slurmctld"
        mkdir -p /var/spool/slurmd /var/log/slurm /var/run/slurm
        chmod 0755 /var/spool/slurmd
        # slurmd must run as root (manages cgroups / job steps).
        log "starting slurmd (node ${SLURMD_NODENAME:-$(hostname)})"
        exec /usr/local/sbin/slurmd -D -vvv -N "${SLURMD_NODENAME:-$(hostname)}"
        ;;

    bash|sh|"")
        exec /bin/bash
        ;;

    *)
        # Allow running arbitrary commands (e.g. sacctmgr, sinfo) in the image.
        exec "$@"
        ;;
esac
