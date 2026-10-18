# 2026-10-15 12:00 — Factory: git as the checkout's owner, the cause quoted, compose's volume

The owner's first real factory run on a machine: `farmy factory start` refused with "the run could not
clone the checkout and check out main: and the repository exists." By hand, a root container cloning the
checkout volume got `fatal: detected dubious ownership in repository at '/src/.git'` and `fatal: Could not
read from remote repository.`: the checkout belongs to the dev user (uid 1001), the run's first git
container ran as root. The fake docker knew nothing of ownership, so the suite was green. Also seen: compose
warned `volume "<name>-src" already exists but was not created by Docker Compose`.

## Decided

1. **Every factory git container runs as the checkout's owner**, the toolbox's dev user (uid 1001), never
   root; git then accepts the repository and what it writes into the run volume is the dev user's. The run
   volume is made the dev user's when it is created, by a short root container whose only command is
   `chown 1001:1001 /workspace`. No `safe.directory '*'` anywhere (git containers and the gate).
2. **A git failure names its cause.** Wherever farmy reports a git failure (the run's clone, its push, the
   service's clone at start), it quotes the first line that names a cause; `detected dubious ownership`
   joins the cause list (FORMATS, the clone marker). When `factory start` refuses, git's full output stays in
   `.work/<name>/runs/<id>/git.log` (the run's folder is kept, without a state, so it is no run in `list`),
   and the refusal names that file.
3. **Compose makes the checkout volume.** farmy's stale-marker cleanup ran a container on `<name>-src` before
   compose up, which made the volume without compose's labels. The cleanup now runs only when the volume
   exists already; a first start leaves it to compose. A volume an earlier farmy made stays unlabelled (the
   warning repeats for it until `farmy destroy <name>`).

## The fake

Volumes have an owner: one made by `docker volume create` (or by a `docker run` that mounts it) is root's; the
checkout volume of an app container is the dev user's (its entrypoint makes it so); `chown <uid>[:<gid>]
<target>` run as root in a `docker run` makes that volume the uid's. A container labelled `farmy.role=git`
whose user (`-u`; dev is 1001, none is root) is not the owner of a volume it mounts fails as git does: with a
repository there, `fatal: detected dubious ownership in repository at '<target>/.git'` and git's following
lines; without one, writable, `fatal: could not create work tree dir '<target>': Permission denied`; exit 128.
Compose warns about a volume that exists without its project's label and is not `external`, as the real one.

## Tests altered

None; the factory tests now pass only with git run as the dev user.

## Scenario list

factory_test.rb
- every git container of a run runs as the checkout's owner, and the run volume belongs to that user
- a checkout owned by another user is refused with git's first line that names the cause, and git's full output is in the run's git.log

start_test.rb
- start leaves the checkout volume for compose to create: compose warns about no volume it did not make
- a clone that fails on ownership names git's dubious ownership line
