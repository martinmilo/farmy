# The shim keeps a control container that factory runs are live in

The owner, 2026-10-26, reported a bug in the shim.

The shim replaces the control container when the containers-folder mount it reads from `docker inspect` does not
equal `$PWD`. It also replaces it when `docker inspect` fails, because an empty answer counts as a mismatch.

Replacing the container kills every factory controller running inside it:
- their runs end `interrupted`;
- their agent containers are killed;
- the unlocking values the holder kept are lost, so the next `farmy factory start` asks for them again, and hangs
  without a terminal.

Observed: two replacements four seconds apart, with an unchanged folder and a live run.

## Decided (the owner)

1. **Never remove a control container that live factory controllers run in.** Where the shim would replace one
   (mount mismatch, out-of-date image, version mismatch), it refuses instead. The message names the live run ids
   and the reason, and the shim exits 1. Two commands are exceptions: `farmy stop` with no name, and
   `farmy factory cancel`.
2. **A failed read is not a mismatch.** When reading the mount fails (`docker inspect` errs or prints nothing),
   the shim keeps the existing container and goes on. If the container is in fact gone, it is created as today.
3. **A mismatch with no live run** still replaces the container, as today.
4. **The shim's tests cover:**
   - a live run: the refusal names its id;
   - an inspect failure: the container is kept;
   - no run and a mismatch: the container is replaced;
   - `farmy stop` with a live run: it stops the runs as it does now.
5. **How the shim learns of live runs** is the worker's choice, as long as it needs only `docker`. Either the run
   containers (labelled `farmy.role` agent, git or test, with `farmy.run`), or the controller processes in the
   control container (`docker top`). FORMATS.md states both.

## What the program does today (a work-side helper's answer)

A read-only helper read the shim and the farmy binary in the work folder; it never looked into this folder. Its
answer shaped the choices below.

**The shim removes the container (`docker rm -f farmy`) on four checks, and none of them looks for live runs:**
- **The mount read.** It asks only for the mount whose destination is `$PWD`. An empty answer counts as a mismatch.
  A failed inspect, a missing container and a container that serves another folder all give that same empty answer.
- **The running version.** A valid version that differs from the shim's replaces the container. An unreadable
  version does not.
- **An out-of-date image.** In a local build this is checked only for `init` and `update`, by the image's
  `farmy.hash`. Otherwise it is checked by the image's `farmy.version`.
- **`init` in a checkout** whose image hash changed.

Every command goes through these checks except `--version` and `update`. Nothing treats `stop` or
`factory cancel` specially.

**Controllers run inside the control container** as `/usr/local/bin/farmy factory run <id>`; pipeline controllers
run as `/usr/local/bin/farmy factory pipeline run <p-id>`.

**A live controller can have no running container at a given moment:**
- queued for a slot;
- waiting for a login turn;
- cloning, between two git containers;
- a pipeline between steps.

**`farmy stop` with no name** stops the services, the knowledge container and the egress node. It does not touch
factory runs. Today the runs end on `stop` only because the shim replaces the container first, when it finds a
reason to.

**`farmy factory cancel <id>`** kills the controller by the pid in the run's `state.json`, then removes the run's
containers. So it can stop a controller only from inside the control container that controller runs in.

## Chosen here (the owner may overrule any of these)

- **`farmy factory cancel` keeps the container and runs in it.** The exception lets cancel through, but replacing
  first would kill every live run, not only the one named. The new container's cancel would then signal a pid
  from another container's process space.
- **`farmy stop` with no name replaces as before.** The live runs end with the container, then stop runs in the new
  one. "Stops them as it does now" can only mean this, since `stop` itself leaves runs alone. The test pins the
  replacement.
- **`farmy stop <name>` is refused like any other command.** The exception is for stop with no name only.
- **What the refusal names, and what the tests assert of it:**
  - every live run's id;
  - the reason: for another folder, that folder's path; for a version, the version it runs (`0.1.0`); for an
    out-of-date image, the word `image`;
  - the way out, `farmy factory cancel` (asserted in the version test).

  The wording is the worker's.
- **Rule 2 covers every inspect of the control container, not only the mount read.** The fake makes every inspect
  of it fail, or answer nothing. The version read already treats an empty answer as no reason.
- **How each reason is staged:**
  - **Another folder:** the shim's `init` really runs in a second containers folder, so the fake holds the
    container exactly as the shim made it there.
  - **A version:** the control image is labelled `farmy.version=0.1.0` while the shim is 0.2.0, the situation
    right after `farmy update`.
  - **An out-of-date image:** the image's `farmy.hash` is changed, then `farmy init` runs. In a local build the
    shim checks the hash only for `init` and `update`.
- **The stop and cancel tests use the version reason**, so the folder is the same. A cancel from another folder
  cannot reach the run's folder (open, below).
- **The tests do not pick the method.** A live run is staged both ways at once: its controller in
  `docker top farmy`, and its agent container running with `farmy.run=<id>` and `farmy.role=agent`.

## How the tests play it

- **The fake docker** learned `inspect_fails`: `docker inspect` of a named existing container fails
  (`Error response from daemon: context deadline exceeded`, exit 1) or prints nothing (exit 0).
  `docker image inspect` is not affected, and a missing container still answers `No such container`. The fake
  already refused a second `docker network connect`, as Docker does. So a shim that keeps the container but trips
  over its own network step after a failed inspect shows that failure.
- **A live run is staged directly in the fake.** In the tests a command handed to the control container is only
  recorded, so no controller can really start there.
- **The kit module** `support/live_runs.rb` (LiveRuns) stages the control container and the run, and checks:
  - **"kept":** the container from before still runs; it was never stopped, removed or made anew; there was no
    `docker rm`, `stop`, `kill` or `restart` of it, and no `run` or `create` with its name.
  - **"made anew for this folder":** a new container that binds this folder at the same path.
  - **The refusal's "nothing behind":** the container is kept, the run's controller and agent are still there, and
    nothing was handed to the container.

## Tests that pass already

Two of the new tests pass today, on purpose. Both are guards against a fix that refuses too much:
- **`farmy stop` with no name:** today the shim replaces on the version reason, then runs stop.
- **Another folder with no live run:** today the shim replaces.

## Open (for the owner)

1. **Which method.** Only `docker top` sees a controller that has no container at that moment. With the label
   method, a queued run, a run waiting for a login turn and a pipeline between steps are still killed by a
   replacement. A test that stages such a run would rule out the label method, so none was written. Say if one
   should be.
2. **Pipelines.**
   - `docker top` shows pipeline controllers, and FORMATS.md names them, but no test stages one.
   - `farmy factory pipeline cancel` is not among the exceptions, so it is refused like any other command.
3. **Read-only commands are refused too.** While a replacement is due, `status`, `factory list`, `show` and `log`
   are refused. They could run in the existing container instead, so the owner can watch the runs to their end.
4. **Cancel from another folder.** The exception hands cancel to a container that serves another folder, and this
   folder is not mounted there. Not tested. One answer: hand it over in the folder the container serves.
5. **After a refused `init`,** the image the shim rebuilt stays rebuilt. This is not asserted either way.
6. **A container that is gone** is made as before. The existing ShimTest tests cover this (a first `init` makes it),
   so no new test was written.

## Tests altered

None. The fake's new switch is off unless a test sets it. FORMATS.md gained:
- a bullet under "Docker in the tests";
- a section, "The control container and live factory runs".

## Scenario list

ShimLiveRunsTest (`test/farmy/shim_live_runs_test.rb`):

1. A control container made for another containers folder is not replaced while a factory run is live in it. The
   shim refuses, naming the run and that folder.
2. A control container that runs another farmy version is not replaced while a factory run is live in it. The shim
   refuses, naming the run, that version and `farmy factory cancel`.
3. `init` does not replace a control container whose image is out of date while a factory run is live in it. The
   shim refuses, naming the run and the image.
4. The refusal names every factory run live in the control container.
5. `farmy stop` naming a service is refused like any other command while the control container is due to be
   replaced and a run is live in it.
6. `farmy stop` with no name is not refused. The control container due to be replaced is made anew as before, the
   live run ends with it, and stop runs in the new one. (Passes today.)
7. `farmy factory cancel` is not refused. It runs in the control container the run is live in, which is kept,
   since only there can it stop the controller.
8. A control container whose `docker inspect` fails is kept, not replaced, and the command runs in it.
9. A control container whose `docker inspect` answers nothing is kept, not replaced, and the command runs in it.
10. A control container made for another containers folder, with no factory run live in it, is replaced by one for
    this folder. (Passes today.)
