# The test kit on a Docker-only host

The owner's Mini run of the real-Docker tests (2026-10-19, in a docker:dind container: `sh -c 'dockerd … &
… bin/verify …'`, JOBS=1) ended 9 runs, 1 failure, 8 skips. The leak check reported and killed 9 processes:
the container's own dockerd, containerd, their shims, docker-init and farmy-knowledge. The shell ran
bin/verify last, so the runner took over its pid; with JOBS=1 the test runs in the runner, the daemon
started before it was its child, and the leak check counted it. With the daemon gone, the remaining tests
skipped as if no Docker were there.

Decided (the owner, 2026-10-19), test kit only:

- The leak check considers only what the test started: processes already below the test's process when the
  test began, and everything below them, are never killed or reported (pid and start time, recorded before
  each test).
- A real-Docker test removes every container it started through Docker after it (`docker rm -f` of the
  containers that were not there before), so the shims and init processes of its containers end through
  Docker, not by the leak check's kill. The shims Docker re-parents to the runner end then, within the leak
  check's grace.
- `REQUIRE_DOCKER=1` turns "needs a real Docker" skips into failures; the Mini command sets it.

Left out: isolating real-Docker tests from each other beyond their containers (volumes, images, networks).

## Scenarios (KitTest)

1. The leak check never kills or reports a process that was running before the test began, nor the children
   it starts during the test.
2. The leak check kills and reports a process the test started and left running.
3. With REQUIRE_DOCKER=1 a test that needs a real Docker fails where none answers, naming REQUIRE_DOCKER.
4. Without REQUIRE_DOCKER a test that needs a real Docker is skipped where none answers.
