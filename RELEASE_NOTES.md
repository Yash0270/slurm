# Release Notes for Slurm 26.05

## Upgrading

Slurm 26.11 supports upgrading directly from 26.05, 25.11, and 25.05.

See the [Upgrade Guide](https://slurm.schedmd.com/upgrades.html) for further details.

## Highlights

## New Features

* Cause-aware batch job requeue limits: node-failure and preemption requeues are
  now counted and bounded separately from launch/prolog-failure requeues, each
  with its own limit and hold reason (JobHoldMaxNodeFailRequeue /
  JobHoldMaxPreemptRequeue).

## Configuration Changes

* Added MaxNodeFailRequeue (default 10, 0 = unlimited) to bound batch job
  requeues caused by node failure.
* Added MaxPreemptRequeue (default 100, 0 = unlimited) to bound batch job
  requeues caused by preemption or scontrol requeue.

## Packaging Changes

## REST API Changes

[Slurm OpenAPI Plugin Release Notes](https://slurm.schedmd.com/openapi_release_notes.html)

* Added new v0.0.46 API endpoints.
* Deprecated v0.0.43 API endpoints (will be removed in Slurm 27.05).

## Deprecations and Removals
