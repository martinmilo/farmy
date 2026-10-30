# Before release: a folder switch keeps live runs, and Linux files are the user's from the start

The owner, 2026-10-29, after the default-home review (record 2026-10-29-1105 listed both as open risks):

> 1. Merge the shim-keeps-live-runs branch into main first and resolve the shim conflict. Then the folder switch must
> obey it: when the control container is serving a different folder and has live runs (session or factory), every
> command refuses with one line naming that folder, the number of live runs, and the two ways out (finish or cancel
> them; or `-C <that folder>`). A control container with live runs is never replaced, by the shim or by a folder
> switch. Test it.
>
> 2. Linux ownership: files and folders farmy creates in the config home and the state home must be owned by the
> invoking user, including everything written during a first bare `farmy` session (farmy.yml, services/, .env,
> .gitignore, .work/). Do it by running as the host uid/gid where files are written, not by a chown afterthought; a
> test that creates the home through a session and checks ownership.

## The merge

Branch `shim-keeps-live-runs` (record 2026-10-26-2126, commit 1f02fe5) was shaped but never built: its 8 new tests
fail. Merging it straight into `main` would leave `main` red. So it is merged into this branch, `keep-live-runs`,
made from `main`; the worker builds both records, and `main` is fast-forwarded on a green full suite.

The conflict was in the tests, not in the shim: that branch touched only this folder. The include lines of both
branches are kept. The helper that makes "another folder's" control container now names that folder in
`FARMY_DIR`, since the kit names the test's folder there for every farmy call (record 2026-10-29-0926).

## What the program does today *(helper)*

A read-only helper read the shim and the binary; it never looked into this folder.

- `docker top farmy` lists every factory controller (`/usr/local/bin/farmy factory run <id>`, `… factory pipeline
  run <id>`), the session's tmux server (`tmux new-session -d -s farmy …`), `farmy tui`, and each attached
  `tmux attach`. Container labels exist only while a run has a container.
- The control container records its folder only in its mounts (and its working folder); there is no label.
- farmy runs as root in the control container: the image has no `USER`, and the shim's execs have no `-u`.
  Ownership comes from a chown when a command ends (`hand_to_folder_owner`). It never runs on a kill. A detached
  controller hands over only when it exits, and a session only when its command ends.
- Running as another uid needs:
  - the Docker socket's group;
  - a home (`HOME` is `/` for a uid without a passwd entry);
  - the hold socket (`/run/farmy`, 0600);
  - one tmux server, because the socket is per uid.
- On a rootless daemon or with userns-remap, `-u <host uid>` maps to a subordinate uid, so container root is the
  right user there.
- The git container that fetches a service's build files bind-mounts `.work/<name>/ctx` and runs as root.
- Agent containers write their verify requests as uid 1001.

## Chosen here (the owner may overrule)

**Live runs**
- Live runs are factory runs and the session, learned from `docker top farmy` only. This settles 2026-10-26's
  open question 1: labels miss the session and runs without a container.
- A factory run counts as:
  - a controller;
  - a pipeline controller;
  - a `--wait` command in the foreground.
- The session counts as live while its tmux server runs, attached or not.
- Each factory run counts one, and the session one.

**The refusal for another folder**
- It is one line, exit 1:
  `farmy: the control container serves <folder> and has <n> live runs; finish or cancel them, or run this command with farmy -C <folder>`
- `<folder>` is written as messages write paths. A default-home container names its config folder.
- "Every command" means every command the shim would hand to the control container: `stop`, `factory cancel`,
  `init` and a bare `farmy` included. `farmy --version` is answered by the shim and stays.

**Another version or an out-of-date image**
- The 2026-10-26 rules stand, with three changes:
  - the session counts as a live run, and the refusal names it;
  - `farmy stop` with no name no longer replaces the container; it runs in the kept one ("never replaced");
  - the refusal also says to leave the session.
- `factory cancel` still runs in the kept container for these two reasons. For another folder, its way out is
  `-C`.

**Who farmy runs as**
- On Linux, when container root is host root, every `docker exec` of farmy uses `-u <uid>:<gid>` of the user who
  runs the shim.
- Everything farmy starts runs as that user too.
- The build-files git container runs with `--user` of the user farmy runs as.
- Rootless and userns-remap daemons (`docker info` security options), a Mac, and a root caller keep root.
- How the control container serves that user (socket group, home, hold socket, tmux) is the worker's choice. The
  real-Docker tests check the result.

**No chown afterwards**
- The chown at command end goes.
- Files an older farmy left root's are handed to the user once, when the shim makes the control container.
  Otherwise a user-run farmy would fail on them; for example, locks are opened read-write.
- Agent containers keep uid 1001 for what they write into a verify queue.

## Existing tests that changed

ShimLiveRunsTest (record 2026-10-26-2126):
- "a control container made for another containers folder is not replaced while a factory run is live in it: the
  shim refuses, naming the run and that folder" now asks for the one line: that folder, 1 live run, the two ways out.
- "the refusal names every factory run live in the control container" is now staged with another farmy version,
  where ids are still named. For another folder, a new test counts them (3 live runs).
- "farmy stop with no name is not refused: the control container due to be replaced is made anew as before …" now
  says: farmy stop with no name does not replace it; stop runs in the kept container, and the run stays live.

Other changes:
- FORMATS.md: the 2026-10-26 section is rewritten as "The control container and live runs". A new section, "Who
  farmy runs as", is added, and the ownership paragraphs now say "the user who runs farmy … from the moment it is
  written".
- The fake docker's `info` lists security options (`daemon_security_options`) and answers a format that names
  `.SecurityOptions`. Any other format gets the whole text, as before.

## Scenario list

ShimLiveRunsTest:
1. A control container serving another folder is not replaced while a factory run is live in it: the shim refuses
   with one line naming that folder, 1 live run, and the two ways out.
2. The session counts as a live run: a control container serving another folder with only its session live is not
   replaced, and the refusal says 1 live run.
3. The refusal counts every live run: two factory runs and the session make 3 live runs.
4. Every command is refused this way, four times over: `farmy stop`, `farmy factory cancel`, `farmy init` and a
   bare `farmy`.
5. `farmy -C <the folder the container serves>` runs the command in that container, which is kept with its live run.
6. A control container serving the default home is not replaced from a project folder while its session is live:
   the refusal names `~/.config/farmy`.
7. Another version with only the session live: refused, naming the session, container kept.
8. `farmy stop` with no name and another version with a live run: stop runs in the kept container (changed).
9. The 2026-10-26 tests otherwise stand: another version, an out-of-date image, ids named, `stop <name>`,
   `factory cancel`, failed or empty inspects, and another folder with no run is replaced (a guard).

HostUserTest:
10. On Linux the shim runs every farmy command in the control container as the invoking user (`-u <uid>:<gid>`).
11. A first bare `farmy` on a terminal runs the session as the invoking user.
12. With a rootless daemon, and with a userns-remap daemon, the shim runs farmy as root (two tests).
13. On a Mac the shim runs farmy as root, as before (a guard).

BuildFromRepositoryTest:
14. The git container that fetches the build files into the state folder runs as the user farmy runs as.

IntegrationTest (real Docker; skipped where none answers, e.g. here. Run on the Mini as a plain user: the test's
own, or uid 4242 with the socket's group when the runner is root):
15. A first bare `farmy` through the real shim makes the default home the invoking user's while its session is
    still attached: `~/.config/farmy`, `farmy.yml`, `services/`, `.gitignore`, `~/.local/state/farmy/.work` and the
    declined marker.
16. `farmy init` through the real shim writes `.env` (and `farmy.yml`) in the default home as the invoking user's.

## Not tested

- `--wait` runs and pipeline controllers as live runs (FORMATS.md names them).
- The one-time hand-back of what an older farmy left root's.
- Socket access, home, hold socket and tmux for the plain user. Only the real-Docker tests show these, and they
  need a Linux Docker Engine: on a Mac, file sharing gives every file to the user.
