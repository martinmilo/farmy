# Before release, part two: sudo, real-host risks, build-file links, a lock, read-only commands, the build

Record 2026-10-29-1530 was built in commit 43583a9, and `main` was fast-forwarded to it on a green full suite. A
read-only helper then reviewed that build against real hosts and left one bug and several risks. The owner,
2026-10-29:

> Start the follow-up round. In it:
>
> 1. The sudo -E bug: ~/.config/farmy is never root's, whoever runs farmy; with sudo -E resolve the home from the
>    invoking user (SUDO_UID/SUDO_USER), same rule as the folder owner.
> 2. The three real-host risks: a Docker CLI warning on stderr must not count as failure; a single failed docker
>    inspect must not change who a command runs as (identity is fixed at container creation, as decided); the
>    one-time ownership fix only hands over files that farmy itself created (its own folders), never a shared
>    folder.
> 3. The symlink problem, as a security fix in this round: build files are read through the git container from the
>    committed tree, symlinks refused or resolved inside the repository only; a test with a build file symlinked to
>    ../.env that must not end up in the image.
> 4. Two terminals creating the control container at once: a lock in the state home around create-or-reuse, so the
>    second waits and reuses.
> 5. Read-only commands (status, help, --version, config path, factory list/show/log, logs, egress log) work while
>    another folder's runs are live; only commands that would replace or reconfigure the container refuse. This was
>    decided earlier; apply it.
> 6. --version shows the build (version plus short commit); bump VERSION to the next pre-release so containers and
>    images from these builds are distinguishable from 0.2.0.
> 7. WSL2 stays documented as unverified, not blocking.
>
> Full suite alone before main moves, as before.

## What the program does today *(helpers)*

Three read-only helpers read the program. None of them looked into this folder.

**sudo and who farmy runs as**
- The shim creates the default home's folders (`mkdir -p`) before it decides who farmy runs as. It never reads
  `SUDO_UID`, `SUDO_GID` or `SUDO_USER`.
- Under `sudo -E`, the folders become root's. The folder-owner rule then sees root, and the control container is
  made for root, with no `farmy.user` label and no hand-back.
- When the user later runs farmy without sudo, a container with no `farmy.user` label counts as made for root and
  is reused as root. farmy keeps running as root for that user until something else replaces the container.

**Reading the control container**
- The shim reads each label with a separate `docker container inspect`, so one command makes six reads of the
  container. One of them failing:
  - `farmy.user`: the command runs as root;
  - `farmy.state`, in the default home: the container is replaced, or the command refused as if the container
    served another folder;
  - `farmy.folder`: the container counts as unknown, and the shim asks `docker info` again to decide who to run
    as.
- When every inspect fails, the container is kept and the command runs as whoever `docker info` now says.
- One read, the `.State.Running` check before a replacement, captures stderr with stdout. A warning line from the
  docker client makes a stopped container look not stopped. The shim then asks `docker top`, which fails on a
  stopped container, and so it keeps the container and refuses the command, quoting the warning as the daemon's
  error.

**The hand-back** (as root in the control container, once when it is made)
- It hands root's files to the user in:
  - the folder itself;
  - `.env`, `farmy.yml`, `.gitignore`, `.git`, `tools.lock`, `services/`;
  - `.work`.
- In a shared folder owned by root it gives that folder and its `farmy.yml`, `services/` and `.env` to whichever
  user made the container.

**Build files**
- Over https and `file://`, a git container clones with a sparse checkout into `.work/<name>/ctx/.src`. farmy
  then copies each file with a copy that follows links.
- A link `../../../../.env` reaches the containers folder's `.env`, which is copied into the build context. A link
  to an absolute path inside a mounted folder works the same way.
- A link to another file in the repository dangles, because the sparse checkout leaves its target out. The start
  is then refused as a missing file.
- Over ssh, a root git container streams the files' contents with `cat`, which follows links inside that
  container.
- `build_files` and `dockerfile` entries are not checked at all. An absolute entry naming a file in a mounted
  folder (`<folder>/.env`) is copied onto itself, which most likely empties it.

**Making the control container**
- There is no lock. Two terminals that both find no container both run `docker rm -f farmy` and then
  `docker run`. One removes the other's new container, or fails with Docker's name conflict.

**Read-only commands**
- `help`, `config path` and `tui --version` are handed to the control container, so they are refused along with
  everything else while another folder's runs are live.
- `--version` is answered by the shim.

**Versions**
- Every check accepts only `MAJOR.MINOR.PATCH`: the shim (its own version included, before it answers
  `--version`), `bin/install`, `bin/release`, `bin/render-release`, `build.rs`, the binary's pins and labels,
  `bin/publish` and the release workflow. `0.3.0-rc.1` is refused by all of them.
- The shim's `--version` prints `farmy <version>`. The binary prints `farmy <version> (<build hash>)`. No commit
  is recorded anywhere.
- The session compares that build hash through tmux's environment, not through `--version`'s output.
- `bin/release` always moves `latest`.

## Chosen here (the owner may overrule)

**1. sudo**
- A root caller under sudo (`id -u` is 0 and `SUDO_UID` names another uid) acts for that user in the default home:
  farmy runs as `SUDO_UID:SUDO_GID`. This holds even when the default home is root's by then, left so by
  43583a9's `sudo -E`.
- The default home is that user's:
  - found from `XDG_*` and `HOME` as always when `HOME` belongs to that user (`sudo -E`, or a Mac's sudo, which
    keeps it);
  - else from that user's home in the user database (`SUDO_USER`);
  - refused (exit 1, naming `SUDO_USER`) when neither can be found.
- The shim settles who farmy runs as before it creates anything. Every folder it makes for the default home is
  made as that user: the config folder, the state folder, missing parents under the user's home, and the lock.
- A root login (no `SUDO_UID`) keeps root's own default home and root.
- For any other folder a root caller still runs as the folder's owner (record 2026-10-29-1530), sudo or not.
- A control container made to run farmy as root for a root caller is never used for a plain user's commands.
  Without a live run it is made anew for that user; with one, the command is refused as for another user.
  Containers in which root is the user (rootless, Mac, Docker Desktop) are not affected.

**2. Real-host risks**
- **A warning is not an answer.** What the docker client prints on stderr is never read as an answer: it does not
  make a running container look stopped, nor a stopped one running, and it is never quoted as the daemon's error.
  The shim reads stdout and the exit code.
- **Reading the control container**
  - Who farmy runs as is read from the control container, which keeps it from the moment it is made. It is never
    re-settled (no `docker info` again) and never guessed (root, or the caller).
  - When a read of the container fails, the shim neither runs farmy as anyone else nor replaces the container for
    it. It may read again; if it still cannot read, it keeps the container and refuses the command (exit 1),
    naming the daemon's error, or that Docker answered nothing.
  - This changes record 2026-10-26-2126's "an inspect that fails keeps the container and the command runs in it":
    the container is still kept, and the command is now refused.
- **The hand-back covers farmy's own folders only:**
  - the default home's config folder and state folder, which farmy makes, with everything in them and the two
    folders themselves;
  - `.work` of a project folder that belongs to the user farmy runs as.
  - Never a project folder itself or what the user keeps in it (`farmy.yml`, `services/`, `.env`, `.gitignore`,
    `.git`, `tools.lock`), and nothing at all in a folder another user owns (a shared folder).
  - Root-owned leftovers in a user's own project folder outside `.work` stay root's. A command that fails on one
    names the file.

**3. Build files: the security fix**
- A service's Dockerfile and build files are read from the committed tree of the branch, through the git
  container, whatever the transport.
- **Links inside the repository**
  - A file that is a link is resolved inside the repository: link by link, each step staying in the tree.
  - The build context gets the content as a regular file.
- **Links that leave the repository**
  - A link that leads out of the repository (above its root, or an absolute path) or to nothing is refused.
  - The refusal (exit 1) names the file and says it points outside the repository, before anything is built. The
    Dockerfile is held to the same rule.
- **What the build context may hold:** nothing of what such a link points at ever enters a build context, an
  image or farmy's output.
- **Path entries**
  - `dockerfile:` and every `build_files` entry must be a relative path inside the repository: not absolute, no
    `..` part, not empty, not starting with `-`.
  - Any other entry is refused (exit 1), naming it, before anything is fetched. No file outside the repository is
    read or written for it.

**4. One maker of the control container at a time**
- The shim takes a lock around reading the control container and making it or reusing it. The lock lives in the
  state home (`$XDG_STATE_HOME/farmy`, else `~/.local/state/farmy`), whatever folder is in use.
- A second shim that finds the lock taken waits, says once on stderr that it is waiting, then reads the container
  the first one made and reuses it.
- The lock is released before the command runs, so commands still run side by side.
- A lock whose holder is gone (a shim killed while making the container) does not hold anyone up.
- This adds the lock file to what the shim creates in the state home when a project folder is in use. Record
  2026-10-29-0926 said nothing is created in the default home then; that still holds for farmy itself.

**5. Read-only commands while another folder's runs are live**
- These commands run while the control container serves another folder that has live runs, or whose runs cannot
  be counted (a failing `docker top`):
  - `status` (and `--json`), `help`, `config path`;
  - `factory list`, `factory show`, `factory log`;
  - `logs`, `egress log`, `tui --version`.
- Each one runs in a container of its own, `docker run --rm` of the control image, which serves this folder as
  the control container would (the same mounts, the same user). Nothing is handed to the control container, and
  nothing is stopped, removed or made in its place.
- `--version` stays the shim's own.
- Every other command is refused with the one line of record 2026-10-29-1215.
- When the container is kept because of another farmy version or an out-of-date image, the 2026-10-26 rules
  stand: read-only commands are still refused there.

**6. The build**
- **The version line.** `farmy --version` prints `farmy <version> (<commit>)` in all three places: the shim
  (answered by itself), the binary, and `farmy tui --version`.
  - `<commit>` is the short commit, 7 or more hex digits, of the source the program was built from.
  - It reads `commit unknown` when the build could not tell (a source with no Git, such as a `FARMY_SOURCE` URL).
  - The shim in a checkout takes the checkout's commit; an installed shim carries the commit of the image it came
    from.
- **The control image** carries that commit as the label `farmy.commit`.
- **The build hash** leaves the version line. The session keeps comparing builds as it does today.
- **The version grammar** gains one pre-release form, `MAJOR.MINOR.PATCH-rc.N` (N a positive integer without
  leading zeros), everywhere a version is read:
  - `VERSION`;
  - the shim and its pins;
  - `farmy update --to` and `bin/install --to`;
  - `bin/release`, `bin/render-release` and the binary's labels.
- **Ordering** follows SemVer: `0.2.0 < 0.3.0-rc.1 < 0.3.0-rc.2 < 0.3.0`.
- **Releases.** `bin/release` of a pre-release pushes its exact tags and never moves `latest`. `bin/publish`
  publishes stable versions only, as before.
- **`VERSION` becomes `0.3.0-rc.1`.** `main` carries 0.2.0's features plus two rounds of real changes (the default
  home, live runs, farmy run as the user), so the next version is a minor one. A control container or image of
  0.2.0 is then another version, and is replaced as one (or kept while runs are live in it).

**7. WSL2** stays unverified, and the getting-started guide says so. It blocks nothing.

## Existing tests that changed

**ShimLiveRunsTest**
- Five tests ran `farmy status` to show the refusal for another folder. `status` is now read-only and runs, so
  they now run `farmy start shop`. Their names are unchanged:
  - one factory run;
  - the session;
  - 3 live runs;
  - the default home;
  - `docker top` failing.
- The table "… is refused too while the control container serves another folder with a live run, as every
  command is" now ends "… as every command that is not read-only is".
- The table "a control container whose docker inspect fails | answers nothing is kept, not replaced, and the
  command runs in it" is now two tests:
  - "… fails is kept, not replaced, and the command is refused, naming the daemon's error: who farmy runs as in it
    is read from it";
  - "… answers nothing is kept, not replaced, and the command is refused, saying it could not be read".

**Versions**
- DistributionTest "farmy --version names the shipped version with a build hash" now reads "… and the commit it
  was built from".
- VersionTest "farmy --version and the TUI report the same build hash" now reads "… the same version and commit".
- ReleaseTest "release publishes all four images … with version latest and metadata in the chosen registry" now
  reads "… with their version, latest only for a stable version (a pre-release never moves latest), and metadata
  in the chosen registry". Its helper checks `latest` by that rule.
- `Distribution::SHIPPED` is `0.3.0-rc.1`.
- Every test that installs, pulls or releases the shipped version now does so with `0.3.0-rc.1`. That includes
  four PublishingDefaultsTest tests outside this branch's files, which fail until the pre-release is accepted.
- Tests that checked for another version "0.3.0" as a substring now match it exactly, since "0.3.0" is a prefix
  of the shipped version:
  - InstallationTest (4) and ReleaseInstallerTest (1) use `assert_reports_version`;
  - DistributionTest's pin and format refusals and its newer-control warning (4 assertions) use a pattern.

**The fake Docker**
- `cli_warning` prints a line on stderr at every call.
- `inspect_fails_once` makes the n-th inspect of a container fail.
- `slow_creates` keeps the creation of a named container under way until another call goes to remove or make a
  container of that name (`rm`, `run`, `create`), or 5 s pass. A container of that name made meanwhile makes it fail
  with Docker's name conflict (exit 125). Holding on the other call, not on a clock, makes two shims without a
  lock meet mid-create on a loaded machine too; a first try with a 2 s clock let the second shim reuse the
  finished container by luck under parallel load.
- A build context keeps a link as a link and never follows it, as Docker does.

## Scenario list

ShimLiveRunsTest:
1. Read-only commands run while the control container serves another folder with a live run: each in a container
   of its own for this folder, the control container kept with its run. One test per command: `status`,
   `status --json`, `help`, `config path`, `factory list`, `factory show <id>`, `factory log <id>`, `logs shop`,
   `egress log`, `tui --version`.
2. `farmy status` runs the same way when `docker top` of a control container serving another folder fails.
3. `farmy --version` answers while the control container serves another folder with a live run, and nothing is
   handed to the container.
4. The changed tests above (`start shop`; the two refusals for an unreadable container).

ShimControlLockTest:

5. Two terminals running `farmy status` at the same moment with no control container make it once. The second
   waits and runs its command in the container the first made; nothing removes it.
6. A shim killed while making the control container leaves no lock that holds up the next command, which makes
   the container and runs.

HostUserTest:

7. Under `sudo -E`, farmy runs in the default home as the user who ran sudo, even when `~/.config/farmy` is
   root's by then. The one-time hand-back names the default home's two folders, to give them back.
8. A control container made to run farmy as root for a root caller (in a folder of root's) is made anew for a
   plain user who runs farmy there, with no live run.
9. With a docker client that warns on stderr at every call, a stopped control container serving another folder,
   with no live run, is replaced by one for this folder.
10. With that warning, a running control container made for the invoking user is kept, and farmy runs in it as
    that user (a guard).
11. When any one inspect of the control container fails (the 1st to the 6th of a command), farmy runs as the user
    it was made for or the command is refused naming the error. The container is kept with its live session. Six
    tests.
12. In a containers folder another user owns (a shared folder), the hand-back names nothing in it.
13. In a containers folder of the user's own, the hand-back names nothing in it outside `.work`: not the folder,
    `farmy.yml`, `services/` or `.env`.

BuildFromRepositoryTest:

14. A build file that is a link to another file in the repository is built with that file's content.
15. A build file that is a link to `../.env` stops the start, naming it and saying it points outside the
    repository; nothing of the containers folder's `.env` reaches a build context or the output.
16. The same for a link `../../../../.env`, which reaches the containers folder's `.env` from the clone today.
17. The same for a link to the containers folder's `.env` by its absolute path.
18. A Dockerfile that is a link out of the repository stops the start the same way.
19. A `build_files` entry that is not a path inside the repository is refused, naming it, and the folder's `.env`
    is left as it was. One test each for `../.env` and the absolute path of the folder's `.env`.

GitContainersTest:

20. Over an SSH git route too, a build file that is a link to `../.env` stops the start, naming it, and nothing of
    the containers folder's `.env` reaches a build context.

Versions (DistributionTest, VersionTest, InstallationTest, ReleaseTest):

21. The shim's `farmy --version` prints the shipped version and the checkout's short commit.
22. The binary's `farmy --version` does the same (changed), and `farmy tui --version` prints the same line
    (changed).
23. VERSION is `0.3.0-rc.1` (the existing test, with the new value).
24. The control image the shim builds from a checkout carries the checkout's commit as `farmy.commit`.
25. A control container that runs farmy 0.2.0 is replaced by this pre-release's, as another version is.
26. `status` marks a toolbox built by 0.2.0 as older than the shipped 0.3.0-rc.1, and one built by 0.3.0-rc.2 as
    not older.
27. `farmy update --to 0.3.0-rc.2` installs that pre-release.
28. `bin/release` of the shipped pre-release pushes its exact tags and never moves `latest` (the changed release
    test).

DocsTest:

29. The getting-started guide says WSL2 with Docker Desktop is unverified.

IntegrationTest (real Docker, skipped here; run on the Mini as root):

30. `sudo -E farmy status` on a fresh machine makes `~/.config/farmy`, its `farmy.yml` and `~/.local/state/farmy`
    the user's, not root's.
31. A default home left root's by an earlier `sudo -E` is the user's again once the user's farmy has made the
    control container.
32. A shared containers folder of root's keeps its owner, and its `farmy.yml` stays root's, when a plain user's
    farmy makes the control container for it.

## Already passing when shaped (guards)

- 14, a link to another file in the repository. A helper expected it to fail (the sparse checkout leaves the
  target out); here it builds.
- 19 for `../.env`: refused today as a file that is not in the repository.
- 11 for the 1st, 2nd, 5th and 6th inspect.
- 10, the warning with a running container of the user's own.
- 6, the killed shim: there is no lock yet to leave behind.
- The five refusals that now run `start shop`.

## Not tested

- The waiting line on stderr while the lock is taken, and where the lock file lies.
- The user-database lookup for plain `sudo` (`HOME` root's). Faking it here would reach the machine's real home.
- `commit unknown`, a `FARMY_SOURCE` build, and the commit an installed shim carries. The fake registry's images
  are not built.
- `bin/publish` refusing a pre-release (unchanged), and the release workflow.
- Parents of the default home left root's by 43583a9's `sudo -E` (`~/.config`, `~/.local/state` when they did not
  exist before). Only someone who ran that unreleased build under `sudo -E` has them.

## Open for the owner

- **Read-only commands while a kept container runs another farmy version** (or an out-of-date image) are still
  refused. The same container of their own would let `farmy factory show` follow a run across an upgrade. That
  would change the 2026-10-26 tests that run `status` there.
- **"Live" is still only the session and factory runs** (record 2026-10-29-1530): `farmy ssh`, `logs -f`, an
  in-flight `start` and unlocked values still end when the container is replaced.
- **What agents write into a verify queue stays uid 1001's.**
- **`farmy update` with no `--to`** moves a pre-release to the latest release, even an older one (0.3.0-rc.1 to
  0.2.0). That is also the way back.
