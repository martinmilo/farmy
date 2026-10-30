# Architecture

What runs where, what is built from what, and what farmy writes. Names are in FORMATS.md.

## The control container

farmy itself runs in a container, so the host needs Docker and nothing else. The shim `farmy`
(POSIX sh) pulls its version of the control image, tagged locally as `farmy:local`.
With `FARMY_BUILD=1` it builds the repository's `Dockerfile`: a Rust build stage produces
the four binaries, and the runtime stage is Alpine with `docker-cli`, `docker-cli-compose`, `docker-cli-buildx`, git,
tmux, bash, curl, the Infisical CLI and the farmy files under `/opt/farmy` (`FARMY_HOME`). The
image carries `farmy.version`, `farmy.format` and `farmy.hash` labels. In a checkout,
`farmy init` rebuilds cached control when its complete build-input hash changes, even without
`FARMY_BUILD`. With `FARMY_BUILD=1`, targetless `farmy update` uses the same source cache. The shim
then keeps one container `farmy` running from it (its process is a sleeper; farmy runs inside through `docker exec`), with:

- `/var/run/docker.sock` mounted: farmy drives the host's Docker through the CLI;
- the folder in use mounted at the same absolute path as on the host, and its state folder too when
  that is another (`~/.local/state/farmy` for the default home `~/.config/farmy`), so that a bind
  mount in a generated compose file means the same thing to the daemon. The shim resolves the folder on
  the host (`-C`, `FARMY_DIR`, the nearest `farmy.yml` up, the default home), creates the default
  home's two folders as you before Docker would as root, and gives every `docker exec` the folder as
  its workdir and, as `-e NAME=value` on the exec only (the shim's own environment, and so the unlock
  command, `security` and `secret-tool`, stay as you had them), `FARMY_DIR`, `XDG_CONFIG_HOME`,
  `XDG_STATE_HOME`, `FARMY_HOST_HOME`, `FARMY_HOST_GIT_TOP` (the nearest `.git` at or above the folder,
  found by looking: a parent's `.git` is not mounted) and the host's Git identity. Every path is tidied
  (no trailing `/`, no `//`) so that the mounts match what Docker reports. Without `HOME` it refuses
  before anything is made; on a Mac it runs git only when `xcode-select -p` succeeds (without the
  developer tools `/usr/bin/git` is a stub that offers to install them);
- the volume `farmy-control` at `/root`, root's home there, for whatever the control container keeps when
  farmy runs as root; made for you on Linux, the volume `farmy-home` at `/home/farmy` as well, which holds
  your home there (below);
- the labels `farmy.folder`, `farmy.state` and `farmy.user`: the folders it serves and the user farmy runs
  as in it (none for root), which is how the shim knows whether it is the right one;
- the holder (`farmy hold`, started by farmy the first time values arrive): the values the host gave, in
  its memory for the life of the control container, at the socket `/run/farmy/hold.sock` (run as you:
  `/tmp/farmy-<uid>/hold.sock`, see below); `farmy lock` ends it.

Every `farmy <command>` is `docker exec -i [-t] [-u <uid>:<gid>] -w <folder> farmy farmy <command>`. A bare `farmy`
is `farmy session`: a tmux session named `farmy` with the TUI in its one window, status bar and
prefix key off (tmux is only how the session survives a closed terminal), replaced when the farmy
binary's build hash differs from the one the session was made with. The control container
is made anew when you run the shim from a different folder (its mounts changed), the selected
control image changes, it was made to run farmy as another user, or it is gone (`docker rm -f farmy`),
but never while runs are live in it (below). The shim reads it as a container (`docker container
inspect`): a plain `docker inspect farmy` answers with the `farmy` network once the container is gone.
It reads it once per command, every field in one inspect, from stdout and the exit code alone: what the
docker client prints on stderr (`WARNING: Error loading config file: …`) is never its answer. An inspect
that fails or answers nothing is read again, twice; then the command is refused, naming the daemon's error
or saying the container `could not be read`, and the container is kept. Who farmy runs as there is read from
it, never re-settled or guessed.

One maker at a time: the shim takes a lock file, `control.lock` in the state home (`$XDG_STATE_HOME/farmy`,
else `~/.local/state/farmy`, whatever folder is in use), around reading the control container and making or
reusing it, and releases it before the command runs, so commands still run side by side. A second shim that
finds it taken says once that it waits, then reuses the container the first made. A lock whose holder is
gone (a shim killed while making the container) is taken over. Should a shim without the lock (another
user's) make the container in the meantime, Docker's `Conflict` makes this shim read it again and reuse it
when it serves this folder for this user.
Published `update` replaces the shim after pulling all release images; the next ordinary command
selects control. See [distribution](distribution.md).

The control container holds the socket, which is root on the Docker VM. It runs no agent and no
app: that is the one place the socket belongs.

### Who farmy runs as

On Linux with Docker Engine, root in a container is root on the host, so farmy does not run as root
there: the shim runs every farmy command in the control container as you, `docker exec -u <your uid>:<your
gid>` (`id -u`, `id -g`), the session included, and everything farmy starts runs as you too (the session's
tmux server and TUI, factory and pipeline controllers, git, the git container that fetches a
dockerfile's build files into `.work/<name>/ctx`). Every file farmy writes in the folder and the state
folder is yours from the moment it is written, while a session is attached as much as after a command;
nothing is chowned afterwards. Agent containers keep their own user, `dev` (1001). What the control
container gives that user, with no change to the image:

- the Docker socket: the control container is made with `--group-add <the socket's group>`
  (`stat -L -c %g` of the socket here; `root:docker 0660` on Docker Engine), which every `docker exec`
  into it gets as well. When the socket's group cannot be read, the shim says so in one line and makes
  nothing, rather than a control container whose farmy cannot reach Docker;
- a home of its own: in the control container your uid has no account, and Docker would give it `HOME=/`.
  The shim passes `HOME=/home/farmy/<uid>`, in the volume `farmy-home`, made (yours, mode 0700) with the
  control container, so that Docker's client config and logins, git's global config and known hosts kept
  there outlive the control container, as root's do in `farmy-control`. What an older farmy kept in
  `/root` stays there, root's; your home starts empty;
- the holder's socket, `FARMY_HOLD_SOCKET=/tmp/farmy-<uid>/hold.sock` (`/run/farmy` is root's), which
  lives only as long as the control container;
- one tmux server for all your commands: tmux keeps its socket per uid (`/tmp/tmux-<uid>/default`).

Who farmy runs as is settled when the shim makes the control container, the one time it asks the daemon
(`docker info -f '{{.SecurityOptions}}'` and `'{{.OperatingSystem}}'`; when those fail, the words of a
plain `docker info`), and kept with it in its label `farmy.user`. Later commands do not ask again, so a
`docker info` that is slow or fails changes nothing. A shell whose group changed (`newgrp docker`, `sg
docker`) is still you: the same uid runs in the same container, as the uid:gid it was made for. Another
uid is due a control container of its own (`it runs farmy as <uid>:<gid>, and you are <uid>:<gid>`;
messages write `root` for root).

`sudo farmy` runs farmy as the owner of the folder (of its nearest existing parent while farmy is about to
make it): root for root's own folders, yours for `sudo farmy -C <your folder>`. In the default home sudo
acts for you, since `~/.config/farmy` is never root's: a root caller whose `SUDO_UID` names another user
runs farmy as `SUDO_UID:SUDO_GID` in that user's default home (`HOME` and `XDG_*` when `HOME` is theirs, as
under `sudo -E`; else their home in the user database; else refused naming `SUDO_USER`), and makes its
missing folders and the lock as that user. A root login keeps root's own home. A control container made to
run farmy as root for a root caller is labelled `farmy.user=0:0` and never used for a plain user's commands:
without a live run it is made anew for that user; with one the command is refused in one line, and the
read-only commands run in a container of their own (below).

Build files come from the committed tree, whatever the transport: the git container clones the branch
(shallow, blobless, no checkout) into its own filesystem, with no mount of the state folder, reads each
selected file with `git ls-tree` and `git cat-file`, and hands it over on its output; farmy, running as
you, writes it into `.work/<name>/ctx` as a regular file. A link committed in the repository is followed
inside the committed tree, link by link; one that leads above the root, to an absolute path or to nothing
stops the start (`points outside the repository`) before anything is written or built, and what it points
at is never read. Over https the git container runs as you. A clone over ssh cannot: ssh refuses a uid the
image has no account for (`No user exists for uid <n>`), and the route's agent answers only its own user and
root. So over ssh (an `ssh://`, `git+ssh://` or `user@host:path` URL, or an `https://` URL that a git
route's `insteadOf` sends to ssh) it runs as root; it writes nothing of yours either way.

Files an older farmy or an earlier `sudo` left root's are handed back once, when the shim makes the
control container, and only in farmy's own folders: a root `docker exec` changes what is root's in the
default home's config folder and state folder (all in them, and the two folders themselves), and in `.work`
of a project folder that belongs to you, to you. Never a project folder itself or what you keep there
(`farmy.yml`, `services/`, `.env`, `.gitignore`, `.git`, `tools.lock`), and nothing in a folder another user
owns: those paths are never handed to it. A root-owned file left there stays root's; a command that fails
on it names it. Links are changed themselves, never followed; it stays on the filesystem each starts on
(`find -xdev`); a hand-back that fails says so in one line, and the command goes on.

Where root in a container is already you on the host, farmy runs as root, as before: a rootless daemon
(`docker info`'s security options name `rootless`), Docker Desktop, a Mac (its file sharing gives your
files to you). A daemon that remaps users (`userns`) keeps root too, but there root is not you: root and
every uid in a container map to subordinate uids on the host, so neither root nor `-u <uid>` writes your
files. Ownership under userns-remap is not farmy's to fix; run farmy with a daemon that does not remap, or
give the remapped uids access to the folder.

### Live runs keep the control container

Replacing the control container ends everything running in it. So the shim asks `docker top farmy` first
and never replaces one with live runs: a factory run's or pipeline's controller (`factory run <id>`,
`factory pipeline run <id>`), a factory command waiting in the foreground (`--wait`), and the session (its
tmux server, attached or not). A process counts by its own words, its command line in `docker top`'s
`CMD` column: farmy's command (`farmy` or a path ending in `/farmy`) followed by `factory run <id>` or
`factory pipeline run <id>`, or `factory` with `--wait` among the words after it; a task text that reads
`factory run …` makes nothing live. A container that is not running has none. From another folder, every
command is refused with one line naming the folder it serves and how many runs are live; `farmy -C <that
folder> <command>` runs there. The read-only commands are the exception (`status [--json]`, `help`, `config
path`, `factory list`, `factory show`, `factory log`, `logs`, `egress log`, `tui --version`): they run in a
container of their own, `docker run --rm` of the control container's image serving this folder as the
control container would (this folder and its state folder at their paths, the socket, the same user), so
nothing is handed to the kept container; they do so too when `docker top` of it fails. When it is due for another farmy version, an out-of-date image or another
user, every command is refused naming each live run and the way out (`farmy factory cancel <id>`, ending
the session), except `farmy stop` with no name and `farmy factory cancel <id>`, which run in the kept
container. When `docker top` fails, whether runs are live cannot be told: the container is kept as if
they were, and the refusal carries the daemon's error (and, from another folder, `farmy -C <folder>`).
`docker top` is asked only when a replacement is due. An inspect of it that fails or answers nothing is no
reason to replace it.

## Images

| Image | Built from | When |
|---|---|---|
| `farmy:local` | `Dockerfile` (the control image: farmy, docker with compose and buildx, git, tmux, the Infisical CLI; `DOCKER_CLI_HINTS=false`) | exact release pulled by the shim; development builds cache by `farmy.hash` |
| `farmy-gate:local` | `gate.Dockerfile`: the `farmy-gate` binary on Alpine | at restricted app or factory start, when missing or its sources changed |
| `farmy-keys:local` | `keys.Dockerfile`: the `farmy-keys` binary from `farmy:local` on Alpine with CA roots | at `start`, when missing or its sources changed (label `farmy.hash`) |
| `farmy-knowledge:local` | `knowledge.Dockerfile`: the `farmy-knowledge` binary on Alpine, with farmy's README and docs under `/kb` | the same, with `knowledge: true` (its sources, the README or the docs changed) |
| `farmy/<name>:base` | the stage `target:` of the repository's own Dockerfile, with `build_files` in the context | at `start`, for a definition with `dockerfile:` |
| `farmy/<name>:dev` | `toolbox/Dockerfile` with `BASE` = `image:` or `farmy/<name>:base`, `AGENTS` = the agents on for the service, and `agents.tsv` in the context (`.work/<name>/toolbox/`) | at `start` |

The four farmy images are Alpine: static binaries, small is all that matters. A service's image
is the one its definition names (one of `image:` or `dockerfile:` is required, nothing is
defaulted); the docs recommend the official Debian `-slim` images, the toolbox's apt path is the
supported one and apk is best effort (README → Images).

Published control and helpers come from the same selected registry and exact version. All
farmy-owned builds, including service base/toolbox builds, carry `farmy.version` and `farmy.hash`.
The release build exports or publishes both supported architectures from `release.Dockerfile`.

The toolbox folder is the containers folder's own `toolbox/` when it has a `Dockerfile`, else
farmy's (`start`/`rebuild` print `custom toolbox: <path>/toolbox` for the former). Farmy appends its
layers to either: the managed tools and packages (unless `toolbox: {managed: false}`), `farmy-home.sh`,
and, last, its own `entrypoint.sh` as `/usr/local/bin/farmy-entrypoint` and the `ENTRYPOINT`, with a
custom toolbox's `start.sh` at `/usr/local/lib/farmy/toolbox-start.sh`; those files sit under
`farmy-layer/` in the context. The `farmy.entrypoint.modes` label is read from that installed entrypoint.
Its hash with farmy's layer files and the agents list is the label `farmy.toolbox.hash` on `farmy/<name>:dev`
and on the app container; `start` says when a running container predates it (`farmy rebuild
<name>` brings it in). `rebuild` passes `--no-cache` to both builds.

For a `dockerfile:` definition, farmy fetches the Dockerfile and the `build_files` from the committed
tree of the branch, through a shallow, blobless `git clone --no-checkout` (above, Who farmy runs as).
`dockerfile:` and every `build_files` entry is a relative path inside the repository (no leading `/`, no
`..` part, not empty, not starting with `-`); any other is refused naming the entry and the service file
before anything is fetched. It starts and loads the service's broker before the fetch. The Git helper
uses `farmy:local`, since the app image does not exist yet, and mounts only the broker's agent socket,
when needed. farmy's own helper images (keys, knowledge, gate) build from a context of their own, holding
only what their Dockerfile copies, as plain files. It receives no key or token bytes.

Service checkout initialization, factory Git, Dockerfile fetches and dotfiles clone/pull all
use `git_container::run`. It creates the helper on the service's broker network, connects it to
`farmy`, and only then starts Git. Every helper receives the same route rewrites, upper/lowercase
proxy variables and local bypasses. SSH resolves the destination through SOCKS5 or HTTP CONNECT
and signs through the loaded broker's agent socket. Helpers are removed after their command ends.

## Containers and volumes of one service

One compose project per service, named after it, in `.work/<name>/compose.yml`:

| Service | Container | What |
|---|---|---|
| `app` | `<name>` | `farmy/<name>:dev`; `init: true`; the checkout on the volume `<name>-src` at `/workspace` (empty for a workbench, `repo: none`); the definition's `mounts:` on `<name>-<mount>`; the service's own `<name>-agents` at `/home/dev/.farmy-service` (a folder per agent; none when no agent is on); `farmy-shared` (shared, external) at `/home/dev/.farmy-shared`; the definition's `ports:` published; network `default`, plus `farmy` when unrestricted and needed; restricted apps use only internal `default` |
| `egress-gate` | `<name>-egress-gate` | present for a restricted app; `farmy-gate:local`, internal `default` plus outward `farmy`, read-only with an owner-only control socket under tmpfs `/run` |
| `keys` | `<name>-keys` | `farmy-keys:local`; read-only, no capabilities, `/run` on tmpfs; `FARMY_ROUTES` and `FARMY_ROUTE_<NAME>` in its environment, no secret; with an `auth: ssh` route, the volume `<name>-keys-agent` at `/run/farmy-keys` for the agent socket, shared with the app |
| the fragment's | as compose names them, or `container_name` | your `compose:` services, verbatim, with `init: true` added when absent |

The app container's environment: `REPO` and `BRANCH` (repository metadata; absent for a workbench), `GIT_USER_NAME` and
`GIT_USER_EMAIL` from `.env`, `DEV_GIT_ROUTES` (`<upstream>=<route URL>` pairs) for the granted http(s) routes with `git: true`,
`FARMY_AGENTS` and `FARMY_MCP_URL` when an agent is on for the service, an agent's `token_env` in
subscription mode (the one secret in a container's environment, see credentials.md; the file names it only,
`NAME: ${NAME}`, and farmy gives the value in the environment of `docker compose` at every up), `SSH_AUTH_SOCK` with an
`auth: ssh` route, the variables and placeholders every granted route exposes, loaded or not (the broker
answers 503 until `farmy keys reload` loads it; except an agent's `api` variables in subscription mode), `DEV_MOUNTS` with the mounts' paths, the definition's `env:` with `${url:x}` and `${port:x}` resolved, `DEV_FORWARD_PORTS`
for the host ports those references point at, `DEV_WORKDIR` when there is a `workdir:`. A later
line wins; `$` is escaped so compose leaves the values alone (all but the token's `${NAME}`). `services/<name>.env` is added through
`env_file`, so it reaches that container only.

`${FARMY_PORT_<n>}` anywhere in the fragment becomes the n-th port of the service's block (the
hundred its first host port lies in). Top-level `volumes`
and `networks` of the definition are merged with farmy's (`src`, `agents`, `farmy-shared`,
`farmy`, and one `<name>-<mount>` volume per entry of `mounts:`).

`stop` is `compose stop`: containers and volumes stay. `restart` and `rebuild` are `compose down`
(volumes kept) and a new `up` from the definition as it is now. `destroy` is `compose down -v`:
every volume the compose file declares goes, the checkout included.

## Inside the app container: `toolbox/entrypoint.sh`

As root: write Git defaults to system configuration, make `/workspace`, the shared `farmy-shared` volume, the service's agents volume and the definition's mounts (`DEV_MOUNTS`, when a volume starts out root's) the dev user's, then drop to `dev` (`gosu` on
Debian, `su-exec` on Alpine). As dev, for each agent in `FARMY_AGENTS` (its line in `/etc/farmy/agents.tsv`): link its login paths
into `farmy-shared/<agent>/` and its state paths into the service's own volume; link the editor servers' extensions into `farmy-shared`; wait for the broker's health;
write the agent's status hooks (`farmy-agent-status <agent> <state>`, on the
service's own volume) when its hooks file has none; run the agent's `mcp_add` once per login;
start a socat forwarder per port in `DEV_FORWARD_PORTS` (so `localhost:<port>` inside reaches the
host as it does in a browser); run a custom toolbox's `start.sh` (`/usr/local/lib/farmy/toolbox-start.sh`)
from dev's home, reporting a failure with its exit status; then wait. The app stays available if the separate Git helper fails.

The app container's `depends_on` names every fragment service with a condition: `service_healthy`
for one with a `healthcheck:`, `service_started` otherwise, and the broker. Compose therefore
starts the app only once the checked sidecars answer. Farmy loads the broker
(`docker exec -i <name>-keys farmy-keys load`), initializes `/workspace` on `<name>-src` as dev
through the shared Git launcher, and records `ok` or `failed` in `/workspace/.farmy-clone`.
After a successful clone it applies dotfiles and runs the `setup` command with
`docker exec -u dev -w <app dir> timeout <setup_timeout> sh -lc <setup>` (exit 124 is reported as
"did not finish within"), and checks that
git reaches the repository's host through the broker.

## The keys broker

`farmy-keys serve` reads its routes from the environment, listens on 9181 for the app and on the
Unix socket `/run/farmy-keys.sock` for `farmy-keys load`. A request to `/<route>/<path>` is
forwarded to the route's upstream with the secret added (basic, bearer or a header), the client's
own `Authorization` and that header dropped, redirects on the upstream's origin rewritten to the
route. A route not loaded answers 503; an unknown route 404. An `auth: ssh` route is an SSH agent
instead: the key stays in the broker, the app container gets the agent's socket. The secrets live
in the process's memory and nowhere else. Details and the guarantee: [credentials.md](credentials.md).

## The knowledge container

`farmy-knowledge` serves an MCP server over HTTP on 9190 to every app container on the `farmy`
network, with farmy's README and docs in its image and the folder's `services/` and
`.work/status` mounted read-only. Nothing farmy generates bind-mounts a path outside the
folder in use and its state folder: the daemon resolves bind sources on the host, where the control container's
`/opt/farmy` does not exist. [farmy-mcp.md](farmy-mcp.md).

## The filtering gate

`farmy-gate serve` starts deny-all on port 9182. The control process loads a complete policy
through its Unix socket before starting a restricted client; the socket never enters that
client. Identity comes from its peer IP, matched to the real container name on Docker DNS.
Clients cannot select policy by an HTTP header. Each request checks its hostname and port;
HTTP goes to the validated URI authority and CONNECT carries opaque TLS bytes. A configured
upstream HTTP proxy is used only after the destination is allowed.

Policy reload is atomic and preserves counters and the last 100 denial records. `log` and
`status` use the Unix socket. Factory runs have separate gates with only their selected agent's
API hosts. Cleanup retains observations in the run record before removing the gate and run
networks; ordinary app gates reset their counts when the process restarts.

## The mesh egress node


With mesh settings (or the legacy empty `egress: {}`) in `farmy.yml`: the container `farmy-egress` (compose project `farmy-egress`,
`.work/farmy-egress/compose.yml`), image `tailscale/tailscale`, on the network `farmy`, no ports,
`TS_USERSPACE=true` with the SOCKS5 and HTTP proxies on `:1055`, the volume `farmy-egress` at
`/var/lib/tailscale`. `farmy start` brings it up before the provider runs, hands it the auth key
(an unlocking value) on the stdin of a `docker exec`, or prints the registration URL it reads from
`docker logs farmy-egress` and waits `join_timeout` for `tailscale status --json` to say
`Running`. Unrestricted containers and the provider get the mesh proxy variables; restricted clients use their filtering gate
(`docs/mesh-egress.md`); the entrypoint sets git's `core.sshCommand` to go through the SOCKS proxy
with `nc -X 5` when `ALL_PROXY` is set.

## What farmy writes

In the folder in use (`~/.config/farmy`, or a project folder), and `.work/` in its state folder
(`~/.local/state/farmy/.work/` for the default home, the project folder's own `.work/` otherwise):

```
farmy.yml                     every default, when the default home is set up or by farmy init, when missing
.gitignore                    when the default home is set up or by farmy config git, when missing
.env                          by farmy init, or a start, when missing
.work/<name>/compose.yml      the compose file; routes and variables, never a secret
.work/<name>/app.env          a copy of services/<name>.env (empty when there is none)
.work/<name>/definition.yml   the definition the containers were made from, for the drift note
.work/<name>/farmy.yml        a copy of farmy.yml at that time, for the same
.work/<name>/ctx/             the build context of a dockerfile: definition
.work/<name>/.devcontainer/   a devcontainer.json for editors
.work/farmy/compose.yml       the knowledge container's compose file
.work/status/status.tsv       the status snapshot the knowledge container serves
.work/<name>/runs/<id>/egress.json   retained factory denial count and recent records
.work/keys.json               the state of each route (loaded, missing, locked...), never a value
```

On a service's agents volume, `<agent>/agent.status` (`<working|waiting|idle>\t<time>`) is written by the
agent's hooks and read by `farmy status --json` through `docker exec`; an agent without hooks is
reported by its process.

```
```

Nothing under `.work/` is promised to stay as it is; delete it and the next `start` writes it
again (the containers keep running meanwhile; `restart` makes them anew).

All of it is the user's who runs farmy, from the moment it is written: on Linux farmy runs as that user in the
control container (see "Who farmy runs as" above), and nothing is chowned afterwards.

## Why Rust, why one binary each

farmy shells out to `docker` and `docker compose` for everything, so the acceptance suite can stand
a fake `docker` on the PATH in front of it and observe every call. The broker and the knowledge
server, and the filtering gate, are separate binaries because they run in their own minimal containers. All four come out
of one `cargo build` in the control image.
