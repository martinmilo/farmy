# Keep live runs and user files: what a real Docker would get wrong

Record 2026-10-29-1215 was built in commit 7ac747e. The full suite was green: 1043 runs, 0 failures, 41 skips.
`main` was not fast-forwarded, because a read-only helper then reviewed the build against how real Docker,
tmux, BusyBox and ssh behave. It never looked into this folder. Its findings shaped every decision below. The
fake Docker hid each of them.

## What the review found *(helper)*

- **A removed control container is never made again.** `docker rm -f farmy` is what troubleshooting tells the
  user to run. After it, `docker inspect farmy` with no `--type` answers with the `farmy` network, and a template
  naming `.Config` fails on it. The shim takes that for "unknown", does not make the container, and `docker start
  farmy` then fails. Every command exits 1 until the network is removed by hand.
- **Build files fetched over ssh are written as root and chowned afterwards.** The owner's brief ruled that out.
  ssh refuses a uid the git image has no account for, so the build runs that clone as root and chowns `.src`
  back on exit. A kill skips the chown, and the root-owned `.src` blocks every later fetch. URLs that reach ssh
  through a route's `insteadOf` rule or `git+ssh://` are not detected as ssh, and those fail outright.
- **A failing `docker top` counts as no live runs**, so a container due for replacement is replaced and its runs
  are killed.
- **`docker info` is asked on every command.** It fails open: a slow or failing daemon flips who farmy runs as,
  which replaces the container, or refuses commands while runs are live.
- **`newgrp docker` changes `id -g`**, so the same user is "another user": the container is replaced, or the
  command refused.
- **A root caller now writes root's files into a user's folder.** 0.2.0 handed them to the folder owner.
- **The home moved** from the `farmy-control` volume (`/root`) to `/tmp/farmy-<uid>` in the container layer.
  Docker logins, git config and known hosts are lost whenever the container is replaced.
- **userns-remap:** record 1215 said root in a container is the user on the host there. It is not: root and
  every uid map to subordinate uids.
- **Smaller gaps:**
  - the hand-back skips the folder and state folder themselves, can cross filesystems, and fails silently;
  - a socket group that can't be read is lost without a word;
  - a run's task text can be counted as a live run;
  - a root caller is named as an empty string in one message.
- **Fine on real Docker:**
  - `docker top` parsing, on Docker Engine, Docker Desktop and OrbStack;
  - `--group-add` reaching `docker exec -u`;
  - tmux and git for a uid with no passwd entry;
  - the hand-back's quoting and its handling of links;
  - the bind-mount fallback for a 0.2.0 container.

## Chosen here (the owner may overrule)

- **The control container is read as a container.** A container that is gone is made anew, whatever else is
  named `farmy`.
- **A `docker top` that fails is treated like live runs.** When a replacement is due, the container is kept and
  the command refused, naming the daemon's error and, for another folder, `farmy -C <folder>`. `stop` and
  `factory cancel` run in it.
- **Who to run as is settled when the control container is made, and kept with it.** Later commands do not ask
  `docker info`. The same uid is the same user, whatever its group.
- **A root caller runs farmy as the owner of the containers folder:**
  - root for root's own folders;
  - the user for `sudo farmy -C <their folder>`.

  This restores 0.2.0's result without a chown, and changes 1215's "a root caller keeps root".
- **The home farmy runs with lies in a volume mounted into the control container**, so it outlives
  replacements as `/root` did.
- **Build files are written into the state folder as the user farmy runs as, whatever the transport.** Over ssh
  that holds too, with no root writer and no chown. How the ssh step and the user's write are joined is the
  worker's choice.
- **userns-remap keeps root, as before.** The docs say ownership there is not farmy's to fix. The test's name
  no longer claims root is the user.
- **FORMATS.md also asks for the smaller items**, with no tests:
  - the hand-back covers the two folders themselves, stays on one filesystem and reports failure;
  - a missing socket group is said;
  - processes count by their own words;
  - messages write `root`.

## Existing tests that changed

- HostUserTest: the userns-remap case is now its own test. The old name was "with a Docker daemon that remaps
  users (userns-remap) the shim runs farmy in the control container as root, which is the invoking user on the
  host". The new one: "… as root, as before: there neither root nor the user's uid in a container is the user on
  the host". Its assertions are unchanged.
- BuildFromRepositoryTest: "the git container that fetches the build files into the state folder runs as the
  user farmy runs as" uses `assert_build_files_fetched_as`. That check now covers every container that bind-mounts
  a service's folder in `.work` read-write. It no longer requires one to exist: a design in which farmy writes the
  files itself is allowed, and the ssh case may need one.
- **The fake Docker:**
  - `docker inspect` with no type fails, as real Docker does, when a template names a field that a network or
    volume has no entry for;
  - `docker top` can fail (`top_fails`);
  - `docker info` answers `.OperatingSystem`, and with `info_format_fails` its formatted calls fail;
  - its git transport refuses ssh to uids other than root and dev, for URLs that really reach ssh.

## Scenario list

ShimLiveRunsTest:
1. A control container removed by hand (`docker rm -f farmy`) is made anew by the next command, though the
   `farmy` network it was on is still there.
2. A control container serving another folder is kept when `docker top` fails: the command is refused, naming
   the daemon's error and `farmy -C` that folder.
3. A control container that runs another farmy version is kept when `docker top` fails: the command is refused,
   naming the daemon's error.
4. `farmy -C ~/.config/farmy` runs the command in the control container serving the default home, which is kept
   with its live session (a guard; it passes today).

HostUserTest:

5. Once the control container is made for the invoking user, a `docker info` that fails does not change who
   farmy runs as (a guard; it passes today).
6. The same with a rootless daemon: the container made to run farmy as root is kept, and farmy runs as root.
7. A shell whose group changed (`newgrp docker`) is the same user: the container is kept with its live session,
   and farmy runs as that uid.
8. A root caller runs farmy as the owner of the containers folder.
9. The home farmy runs with in the control container lies in a volume mounted into it.
10. userns-remap keeps root (renamed, see above).

GitContainersTest:

11. Build files fetched over an ssh git route are written into the state folder as the user farmy runs as, with
    no container writing them as root.

## Not tested

- The hand-back's details, the socket-group message, how processes are matched, and `root` in messages. The fake
  runs none of these, and FORMATS.md states them.
- What 0.2.0 kept in root's home is not carried into the user's new home. After the upgrade, a Docker login made
  through farmy is needed once more.

## Open for the owner

- **WSL2 with Docker Desktop.** Bind mounts from a WSL distro keep raw uids, so container root writes root's
  files there; this is the review's belief and is unverified. 0.2.0 chowned them back. This build leaves them
  root's, because Docker Desktop keeps root. Running as the user there depends on the socket's group inside
  Docker Desktop's VM, which nobody here can check.
- **Read-only commands are refused too** while another folder's runs are live (`factory list/show/log`,
  attaching to that session), as "every command" says.
- **"Live" is only the session and factory runs.** These still die when the container is replaced: `farmy ssh`,
  `logs -f`, an in-flight `start` or `rebuild`, and unlocked values.
- **What agents write as uid 1001 into a verify queue stays 1001's.** 0.2.0 chowned it at each command's end.
