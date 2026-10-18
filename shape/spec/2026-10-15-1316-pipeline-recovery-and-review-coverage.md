# Pipeline recovery and review coverage

This closes gaps in the already-approved pipeline scenarios without adding product behavior. The
owner accepted P2/P3/P8 and PS15/PS18/PS25/PS34, including their second-review amendments. Tests remain
on the shaper side; the worker is implementing independently and is not inspected. Builds and program
tests wait for coordination with the worker; syntax and fake-only checks do not run the implementation.

## Approved contracts exercised

- **PS15 / P2:** Persist a child's identity before launch. An interrupted launch may leave Docker
  resources without a live agent; resume reconciles that identity, cleans up incomplete work, and
  continues once. A one-shot fake Docker barrier after checkout-volume creation makes this boundary
  observable through public status and the created volume. The test crashes only its fixture controller
  and descendants, leaves partial checkout data on that volume, and requires the resumed run to discard
  that residue. The fake does not decide pipeline state or recovery.
- **PS18 / P3:** An approved attempt can be revised only before its downstream work starts. Once a
  worker is running, revision is refused and cannot invalidate its approval or replace that child.
  Revision also retains the original profile/gate snapshot when the live definition changes.
- **PS25 / P2:** The handoff budget survives recovery of an active pipeline after one question has
  already been answered. Resume must adopt the existing child and reject a subsequent question at the
  configured boundary before starting another answering shaper.
- **PS34 / P8:** Excess runs queue FIFO per service. Two distinguishable queued tasks must start in
  submission order as occupied execution slots become available.

## Scenario list

1. A pipeline exposes its assigned child ID before the first checkout volume operation returns, and after a controller crash resume cleans partial checkout residue and completes that same child with exactly one agent invocation.
2. Revising an approved attempt whose downstream worker has started is refused without invalidating the approval, changing the active child, or launching another agent.
3. Revising an approved standalone shape attempt after its live profile changes still uses the saved write permissions, check, and red_first gate and returns its changed test to review.
4. Two queued tasks begin in submission order as a service with concurrency one releases its occupied slot.
5. Recovering an active pipeline after its first handoff preserves a one-handoff limit, adopts the existing worker, and refuses its next question without another shaper launch.

These scenarios extend the existing pipeline and concurrency tests. The existing snapshot-storage
case stays in place; its additional revision case observes use of the snapshot through the resulting
test commit and gate result. No sidecar configuration combinations or other new scenarios are added.

Observation waits use a 45-second harness watchdog and fake barriers allow 90 seconds. These are not
product latency requirements: broad parallel verification exhausted the former 12-second observation
wait while the public status still showed progress, and the complete pipeline passed in isolation.
Polling intervals remain short, and the longer fake barrier keeps fixture work blocked until the
observer has inspected it or teardown stops its controller.
