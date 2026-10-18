# A pipeline never cleans up a child it has just launched

PipelinesTest failed in 6 of 10 runs alone on main (2026-10-17). Two causes, both found with a fake
Docker that logs which farmy command made each call, and a 25 ms sampler of state, processes and locks.

## Kind 1: the controller removes its own fresh child's checkout (farmy)

`drive_pipeline` spawns the preassigned child and, in the same loop pass, asks whether it is alive. The
check reads `/proc/<pid>/cmdline` for "factory"; a few microseconds after spawn returns the child can still
be inside execve with an empty cmdline, so it counts as dead and the controller runs its abandoned-run
cleanup on it: `docker volume rm -f shop-run-<child>` while the child creates and clones that volume
(and the controller overwrites the child's state.json with its own pid). Seen with `pipeline start
--wait`, the detached `pipeline run` and `pipeline resume`, on first and later children. The window is
inside the kernel's execve, so no black-box test can hold it open.

Decided (the owner): the acceptance tests below are regression guards (they pass on the current code
nearly every time); the worker adds a Rust unit test in work/ with an injected liveness check, failing
today: a child this controller spawned counts as alive until its own Child handle (try_wait) says it
exited. Fix: liveness of the controller's own children comes from the handle, of anything else from the
run's lock; the branch that overwrites the child's state.json goes; every caller of the cleanup is
covered; `cancel` keeps calling it on purpose.

Guards (fake Docker holds each run's very first docker call up to 1 s, or until another process removes
its checkout, and records who creates and removes each checkout volume):
- pipeline start --wait leaves each child's checkout to that child, through a question, its answer and
  the continuation;
- a detached pipeline controller does the same;
- resume cleans an interrupted checkout before relaunching, then leaves the relaunched child's checkout
  to the child.

## Kind 2: a resume issued as the controller dies starts no controller (the test)

`interrupt_pipeline_controller` sent SIGKILL and returned; `pipeline resume` ran at once, saw the dying
controller still alive (its cmdline still read "factory"), returned and started nothing, and nothing else
ever starts one, so the pipeline stayed running. A zombie is not the cause: its cmdline reads empty.
Fixed in the kit: the helper sends KILL, reaps the controller when it is the test's own child, and
polls until the pid is gone (10 s, then fails naming the pid), as a real crash would be over before a
resume.

Farmy hardening, after 0.1.0 (decided, tests to come): resume and status judge controller liveness by
the pipeline's controller.lock, not state.json's pid; status shows an interrupted pipeline with the
resume command; resume waits up to 2 s for the lock and otherwise reports "already running" naming the
pid; state.json is written only on change and its pid is informational. The controller's 100 ms rewrite
of state.json is a side effect of its polling loop, not a heartbeat.
