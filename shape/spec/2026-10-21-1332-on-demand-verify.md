# On-demand verify: the agent runs the suite as often as it likes, and still cannot read it

The owner, 2026-10-21. A profile with `hidden: [test/]` covers that folder with an empty read-only tmpfs in the
agent's container. The agent then cannot run the suite either: its only feedback is the gate, once per iteration.
The two-agent layout farmy is built for (the worker runs the tests and never reads them) needs **run but not read**:
the agent runs the suite whenever it likes, and the test files stay unreadable to it.

## Decided (the owner)

1. A profile (and the legacy single block, which is the profile `default`) accepts an optional
   `verify: <a name under commands:>`. Without it nothing changes. With it, the agent's container has a program
   `farmy-verify` on its PATH. How it reaches farmy is the worker's choice, within: no farmy binary, no Docker
   socket and no broker in the agent's container (it must work in token and login mode, where there is no broker),
   and the agent stays on its internal network.
2. `farmy-verify [args…]` snapshots the agent's current tree the way an iteration commit does (protected and
   hidden paths as at the run's starting commit, changes under `writes` taken, everything else dropped) as a
   scratch commit that never lands on the run's branch; exports that commit into a fresh test container isolated
   as the gate is (no way out, fresh sidecars, a scratch HOME); runs the named command with the args appended;
   passes the command's stdout and stderr back as they come; exits with the command's exit code. Exits 124, 125,
   126, 127 and sidecar or health failures are reported to the caller as such, apart from a failing suite.
3. The hidden folders are in the test container (they are part of the commit) and never readable by the agent:
   `farmy-verify` returns only the command's output and exit code, never files.
4. The run record keeps every call, `iteration-<i>.verify-<k>.log` (args, start, end, exit code, the full
   output), and a count per iteration in `state.json`. Verify time counts toward `iteration_timeout` (the agent is
   waiting), never as an iteration. One verify at a time per run: a second call while one runs waits.
5. The gate stays exactly as it is: a passing verify is not a passing gate. `farmy factory show` lists the verify
   count per iteration.
6. Refused before launch: `verify` naming a command not under `commands:`. `verify` on a profile with
   `gate: {network: none}` is allowed and then runs without sidecars, like its gate.

## Chosen here (the owner may overrule any of these)

- **Where it is refused.** `farmy factory start` refuses, naming the command and `commands:`, before any run
  container starts; `farmy start` accepts the key without checking it, as it does for `test`.
- **Could not run.** When the verify cannot run the command at all (the snapshot failed, Docker refused a
  container, a sidecar was not healthy within `gate.health_timeout`, `gate_setup` failed), `farmy-verify` prints
  `farmy-verify: could not run: <reason>` on stderr, a sidecar named by its compose service
  (`sidecar postgres is not healthy`), and exits 125, the code the gate already uses for a test that failed to run.
  None of the command's own output is there, because the command never ran.
- **The command's own 124 to 127.** `farmy-verify` exits with that code and adds one last line on stderr:
  `farmy-verify: the command exited 124: it timed out`, `…125: it could not be run`, `…126: a program it runs
  could not be executed`, `…127: a program it runs was not found`. Other exit codes get no added line.
- **The snapshot is taken when the call's turn comes.** A call that waited is snapshotted after the one before it
  ended, as if it were made at that moment. The agent's tree, its run branch and that branch's index are left
  exactly as they were: making the snapshot changes no file the agent can see.
- **The verify container** is named `<name>-run-<id>-verify-<i>-<k>`, labelled `farmy.role=verify`,
  `farmy.iteration=<i>`, `farmy.verify=<k>` (with `farmy.run` and `farmy.service`), and is built like the gate's
  test container: the run volume read-only at `/workspace`, `--tmpfs /scratch:exec`, the scratch commit exported
  into `/scratch/tree`, HOME and TMPDIR under `/scratch`, the definition's `mounts:` read-only, no proxy variables.
  It gets fresh copies of the sidecars in a compose project of its own, `<name>-run-<id>-verify`, made as the
  gate's are and removed when the verify ends; with network none it gets `--network none` and no sidecars. The
  profile's `gate_setup` runs before the command when the profile has one, as at the gate.
- **The args** are appended to the command's line, each shell-quoted as one word.
- **A verify never outlives its agent.** When the agent's container ends (it exited, it was stopped at
  `iteration_timeout`, the run was cancelled) while a verify runs, farmy stops it (container and sidecars removed)
  before the iteration's commit; its record says `reason: stopped: the agent's container ended`. A call still
  waiting then never runs, and is recorded the same way.
- **The prompt.** With `verify`, the agent's prompt says it may run `farmy-verify [args…]` as often as it likes,
  names the command line it runs, says it tests a snapshot of the tree as the iteration commit would make it (the
  hidden folders are there, though the agent cannot read them), and says its result decides nothing; only the
  gate does. Like the question instructions, this is supplied even when `factory/prompt.md` omits it. Without it an
  agent would not know the program is there.
- **The record format**: header lines `key: value` (`args` as a JSON array, `command`, `commit` or `-`, `started`,
  `ended`, `exit`, and `reason` when there is one), a blank line, then everything the command printed, both
  streams, in the order it came. `state.json` gains `verifies: [{"iteration", "count"}]`, one entry per iteration
  whose agent ran, 0 included. `factory show` appends `  verifies <n>` to each iteration's line
  (`  1  commit 9834b253c96e  exit 1  verifies 2`). Seen by running the current program through a throwaway
  probe test; no work-side code was read.
- **The agent's network.** Read strictly: nothing joins the agent's internal network for the verify that has a
  way out or holds a secret, and the control container (which holds the Docker socket and the held values)
  never joins it.
- **Slots.** A verify belongs to its run's slot; it takes no `factory.concurrency` slot of its own.

## How the tests play it, and what that asks of the mechanism

The fake plays the agent; it now also runs the agent's command lines for real (`steps`). As with git and test
containers, each container path in the line and in the container's environment is mapped to its folder (a volume,
a bind's source, a fresh folder per tmpfs, so a hidden folder reads empty). PATH is the container's, and a file
bound into a folder on it is found by its name. The fake cannot run a program only the image carries, resolves no
container name for the agent's commands, and does not map paths written inside a program's own files. So under the
tests, `farmy-verify` must be mounted into the agent's container (a bind from the run's folder, or a volume),
must reach farmy through something mounted there (files, a FIFO, a Unix socket), and must find it through its
environment, its arguments or its own location. A shaper-side prototype (a sh script on a bind, FIFOs for the
streams, a small loop running the verify container) passed through the fake, including the time limit and the stop.
A network relay is not ruled out on a real Docker; it cannot be exercised by the fake.

The fake also learned: a `verify` container is listed as running while it runs, and `docker stop`, `kill` and
`rm -f` end it and return once it has ended, as Docker's do. Every `docker run` keeps when it started and ended.
A test can make every verify's sidecars unhealthy (`verify_sidecars_unhealthy`).

## Known limit, for the owner

Hidden means unreadable, not secret. The suite runs code the agent wrote, and that code's output reaches the
agent, so an agent that wants a hidden test's text can print it from its own code during a verify. This channel
already existed through the gate's output in the next prompt; verify makes it immediate. Every verify's full
output is kept in the run record, so such a run can be seen afterwards. The layout depends on the worker not
trying to read the tests, not on making that impossible.

## Left out

`status --json`, the TUI and `factory log` showing verifies; a time limit for one verify other than the
iteration's; verifies across runs (each run has its own one-at-a-time); anything red_first-specific (a verify only
runs its command).

## Open: real Docker, for the Mini

The exchange the worker picks must work where the containers folder is shared from macOS (OrbStack): a FIFO or a
Unix socket on a shared folder may not work there, plain files do. The agent runs as dev (1001), farmy as the
control container's user, and both must be able to use the exchange. Output should still arrive as it comes there.
None of this is visible to the fake.

## Tests altered

None. The fake's additions change nothing an existing test relies on. `factory_service` gains `verify:` and
`sidecar: :health_checked` (the postgres sidecar with a healthcheck).

## Scenario list

FactoryVerifyTest (factory_verify_test.rb): what a call gives the agent
1. a verify of a tree that passes gives the agent the command's stdout and stderr apart, and exit 0
2. a verify of a tree that fails gives the agent the command's output and its exit code
3. the agent's arguments are appended to the verify command, each as a word of its own
4. farmy-verify passes the command's output on as it comes: the first line reaches the agent before the command ends
5. to 7. a verify command that exits 124, 126 or 127 is reported to the agent as such, apart from a failing suite
8. a verify whose sidecar never becomes healthy tells the agent it could not run, naming the sidecar, with exit 125,
   and the run goes on to its gate
9. with verify the agent's prompt names farmy-verify and the command it runs, even when factory/prompt.md says
   nothing of it
10. without verify in the profile the agent's container has no farmy-verify (a guard: it passes today)
11. a verify naming a command that is not under commands: is refused before the run starts, naming it

FactoryVerifySnapshotTest (factory_verify_snapshot_test.rb): what a verify tests, what the agent keeps
12. a verify runs the protected tests as the run started them, not the agent's edit of them
13. a verify leaves the agent's tree as it was, its edits to protected files and outside writes included
14. a verify's commit never reaches the run branch: the pushed branch holds only the iteration's commit
15. a passing verify is not a passing gate: the gate tests what the agent leaves at the end
16. a hidden folder cannot be read in the agent's container, yet the verify runs the tests in it
17. after a verify no file the agent's container can see holds anything of the hidden folder

FactoryVerifyContainersTest (factory_verify_containers_test.rb): where a verify runs
18. each verify runs in a fresh container labelled farmy.role=verify, the run volume read-only, with a scratch
    tmpfs and no way out
19. a verify gets fresh sidecars of its own in shop-run-<id>-verify, removed when it ends, and the developer's
    sidecar never joins
20. with the gate's network none a verify runs with no network and starts no sidecars
21. a second verify called while one runs waits for it, and each call gets its own result
22. a verify still running when the agent is stopped at iteration_timeout is stopped with it
23. in token mode, with no broker, farmy-verify works while the agent stays on internal networks, with no Docker
    socket and no farmy binary

FactoryVerifyRecordTest (factory_verify_record_test.rb): the record
24. every verify is kept as iteration-<i>.verify-<k>.log: its args, start, end and exit code, then its full output
25. state.json counts each iteration's verifies, and a verify is not an iteration
26. factory show lists each iteration's verify count
