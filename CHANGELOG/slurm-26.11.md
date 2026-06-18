## Changes in 26.11.0

* Add cause-aware batch job requeue limits. Node-failure and preemption requeues are now bounded by their own configurable limits, separate from launch/prolog-failure requeues (MaxBatchRequeue).
* Add MaxNodeFailRequeue config option (default 10, 0 = unlimited) bounding how many times a batch job may be requeued due to node failure before being held with reason JobHoldMaxNodeFailRequeue.
* Add MaxPreemptRequeue config option (default 100, 0 = unlimited) bounding how many times a batch job may be requeued due to preemption or scontrol requeue before being held with reason JobHoldMaxPreemptRequeue.
