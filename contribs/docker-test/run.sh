#!/usr/bin/env bash
# run.sh - one-shot: build, start, register QoS, smoke test the cluster.
# Run from this directory (contribs/docker-test/): ./run.sh
# Requires the Docker daemon to be running (open Docker Desktop first).
set -euo pipefail
cd "$(dirname "$0")"

# Fail fast with a clear message if Docker isn't up.
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running."
    echo "       Start Docker Desktop (open -a Docker) and re-run ./run.sh"
    exit 1
fi

echo "==> [1/4] Building SLURM image from local source (first build is slow)…"
docker compose build

echo "==> [2/4] Starting cluster…"
docker compose up -d

echo "==> [3/4] Registering accounting + QoS (low/high)…"
# Give slurmctld a moment to come up before registering.
sleep 10
./register_cluster.sh

echo "==> [4/4] Smoke test…"
docker compose exec -T slurmctld sinfo

echo
echo "Cluster is up. Run the requeue limits test:"
echo "  ./verify_requeue_limits.sh"
echo
echo "Teardown:"
echo "  docker compose down -v"
