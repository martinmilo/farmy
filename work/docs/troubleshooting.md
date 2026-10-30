# Troubleshooting

Every refusal names what to look at: a file, a key, a command. What follows is the same list, with
what to do.

## The shim and the control container

- **`farmy: docker is not installed`**, **`Docker isn't running`**: Docker is the one thing farmy
  needs on the host. Start OrbStack, Docker Desktop or the engine, then try again.
- **The control image takes long**: the first `farmy` builds `farmy:local` (a Rust build in
  Docker, a few minutes). Afterwards it is instant. After a `git pull` of farmy, `farmy init` or
  `farmy update` builds it again when its inputs changed (the label `farmy.hash`).
- **`farmy: 0.4.0-rc.1 is newer than the latest release, 0.3.0; use --to 0.3.0 to go back`**: you run a
  release candidate, and neither the latest release nor a newer candidate (`next`) is published yet.
  `farmy update` without `--to` never goes back; nothing was changed. Stay on it, or go back on purpose
  with the `--to` it names.
- **`farmy` opens the wrong folder**: the control container serves one folder (and its state
  folder); running farmy for another folder makes the container anew for that one, unless runs are
  live in it (next item). `farmy config path` says which folder a command uses.
- **`farmy: the control container serves ~/.config/farmy and has 1 live run; finish or cancel them, or
  run this command with farmy -C ~/.config/farmy`**: a factory run, a pipeline or the session is live in
  the control container, which serves another folder than this command's, and replacing it would end
  them. Either run the command in that folder (`farmy -C ~/.config/farmy status`, or from inside it), or
  end what is live there: `farmy -C ~/.config/farmy factory list` shows the runs,
  `farmy -C ~/.config/farmy factory cancel <id>` cancels one, and the session ends with
  `docker exec [-u <uid>:<gid>] farmy tmux kill-server` (detaching keeps it). The next command for
  this folder then makes the container anew. Meanwhile the read-only commands for this folder (`status`,
  `help`, `config path`, `factory list`, `factory show`, `factory log`, `logs`, `egress log`, `tui
  --version`) still run, each in a container of its own (`docker run --rm` of the control image).
- **`farmy: the control container is due to be replaced (it runs farmy 0.1.0, and this farmy is
  0.2.0), but runs are live in it`** (or `its image is out of date`): after an update or a rebuild of
  the control image the container waits for the runs it names. Wait for them to end, or cancel each
  with the `farmy factory cancel <id>` it gives, and end the session as it says; `farmy stop` (no
  name) and `farmy factory cancel <id>` run in the kept container meanwhile. The next command after
  that replaces it.
- **`whether runs are live in it cannot be told: docker top farmy failed: …`**: the control container
  is due to be replaced (another folder, version, image or user), and Docker did not say what runs in it
  (a daemon that does not answer in time: `context deadline exceeded`). It is kept as if runs were live,
  and the command is not run. Try again once Docker answers (`docker top farmy` works); from another
  folder, `farmy -C <the folder it names> <command>` runs there meanwhile, as do this folder's read-only
  commands in a container of their own, and in a container due for another version `farmy stop` and
  `farmy factory cancel <id>` run in it.
- **`the control container farmy could not be read (docker container inspect farmy: …)`** (or `… answered
  nothing`): Docker did not answer three reads of the control container. farmy keeps it, does not guess
  who it runs farmy as, and runs nothing. Try again once `docker container inspect farmy` answers; a daemon
  that does not answer in time (`context deadline exceeded`) usually does after a moment, else restart
  Docker.
- **`another farmy is making or reading the control container; waiting for it`**: two farmy commands
  started at the same moment; the second waits until the first has made or reused the control container
  (a build of the control image can take minutes), then runs in it. The lock is `control.lock` in
  `~/.local/state/farmy` (`$XDG_STATE_HOME/farmy`); one left by a farmy that was killed is taken over by
  the next command, so there is nothing to remove by hand.
- **`the control container runs farmy as root and has 1 live run`**: it was made by `sudo farmy` (or a
  root login) for a folder of root's, and it is never used for your commands. Finish or cancel what is
  live as root (`sudo farmy factory cancel <id>`); the next command then makes it anew for you.
  Read-only commands run meanwhile in a container of their own.
- **`Error response from daemon: No such container: farmy`**: an older shim after the control container
  was removed (`docker rm -f farmy`, or `FARMY_BUILD=1 farmy update`) while the `farmy` network stayed:
  its plain `docker inspect farmy` found the network. This farmy reads the container as a container and
  makes it anew.
- **`it runs farmy as 1000:1000, and you are 1001:1001`**: the control container was made for another
  user (uid) of this machine; it is made anew for you when nothing is live in it. A shell whose group
  changed (`newgrp docker`) is the same user and is not refused.
- **`cannot read the group of the Docker socket …`**: on Linux farmy runs as you in the control
  container and reaches Docker through the socket's group; `ls -l` the socket the message names, and make
  it readable for you (`stat -L -c %g <socket>` must answer). Nothing was made.
- **`handing root's files in … to 1000:1000 failed: …`** (or **`could not make farmy's home …`**): the
  one-time hand-back when the control container was made could not change everything (it covers farmy's
  own folders: the default home's two, and `.work` of a project folder of yours); the line says what.
  farmy goes on, and may fail where a file is still root's: `sudo chown -R "$(id -u):$(id -g)"` on what it
  names, or `docker rm -f farmy` and the next command tries again.
- **Files of farmy's on Linux belong to a uid that is not yours**: a Docker daemon that remaps users
  (`userns-remap`): root and every uid in a container map to subordinate uids there, so farmy cannot write
  as you; this is not farmy's to fix. Use a daemon without remapping, or a rootless one.
- **`sudo farmy` wrote files as another user**: run as root, farmy runs as the owner of the folder (of its
  nearest existing parent while it makes it): the folder owner for `sudo farmy -C <their folder>`, root
  for root's own folders. In the default home it runs as the user who ran sudo (`SUDO_UID:SUDO_GID`), and
  makes the default home's folders as that user.
- **`under sudo the default home is dana's, and neither HOME nor the user database names a home of
  theirs`**: `sudo` without `-E` gave farmy root's `HOME`, and no home was found for `SUDO_USER`. Use
  `sudo -E farmy`, run farmy as that user, or name the folder with `-C <dir>`.
- **Files of farmy's that are root's on Linux** (left by an older farmy whose run was killed):
  the shim hands them back to you when it makes the control container, in the default home and in
  `.work` of a project folder of yours; `docker rm -f farmy` and any farmy command make it anew (when
  nothing is live in it). farmy itself runs as you there, so it writes no root files any more. A
  root-owned file elsewhere in a project folder (`farmy.yml`, `services/`, `.env`) stays root's, and the
  command that fails on it names it: `sudo chown "$(id -u):$(id -g)"` it.
- **The session is gone**: `docker rm farmy`, or the control container made anew (for another folder,
  another version, a new image: never while the session or a run is live in it), removes it with its
  tmux session; the services keep running. `farmy` makes a new session.
- **`the default home needs HOME, which is not set or not an absolute path`**: farmy was started
  without `HOME` (a service manager does that) and found no other folder. Set `HOME`, or
  `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, or name the folder with `FARMY_DIR` or `farmy -C <dir>`.
- **A Mac offers to install the developer tools**: the shim runs git only when `xcode-select -p`
  succeeds, so this comes from elsewhere; without the tools farmy hands over no Git identity, and a
  start without `.env` asks you to run `farmy init`.

## Before anything starts

- **`no .env in ~/.config/farmy and no Git identity to write one with`**, **`GIT_USER_NAME is not set
  in .env`**: a start writes a missing `.env` itself when it finds your Git identity
  (`GIT_USER_NAME` / `GIT_USER_EMAIL`, or `git config --global user.name` / `user.email`); `farmy init`
  writes it and asks for what it does not find; set it by hand otherwise.
- **`unknown service 'x' in ~/.config/farmy — known: notes shop`**: there is no `services/x.yml` in
  the folder in use; `farmy add <url> --image <image>` writes one.
- **`ports.yml is not read any more`**: the host ports went into each definition as
  `ports: ["3100:3000"]`; delete the file.
- **`services/shop.yml: no repo:`**, **`repo: acme/shop is not a clone URL`**: `repo:` is the full
  clone URL (`https://github.com/acme/shop.git`), or `none` for a workbench.
- **`shop and notes both have host ports in the block 3100-3199`**: a service owns the hundred its
  host ports lie in; give one of them another hundred.
- **`services/shop.yml: ports: the host port 5432 is outside the service's block`**: all of a
  service's host ports stay in one hundred.
- **`services/shop.yml: no ports: but services/notes.yml refers to it`** (a warning): farmy gave
  the service the next free block and wrote `ports: ["3100:3000"]` into the file; change the
  container port if the app does not listen on 3000.
- **`services/shop.yml: unknown key 'x'`**, **`farmy.yml: unknown key 'x'`**: a typo, or a key from
  an older version; the keys are listed in FORMATS.md.
- **`services/shop.yml: the compose fragment defines a service named 'app'`**: farmy adds `app` and
  `keys` itself; rename yours.
- **`services/shop.yml: keys: names 'anthropic', which is not granted to shop`**: the route has
  `services:` without shop; add shop there or drop it from the definition.

## Claude Code

- **Claude asks to log in inside the container**: subscription mode needs either a login on the
  shared volume (log in once, in any container) or the token from `claude setup-token` under
  `CLAUDE_CODE_OAUTH_TOKEN` (the entry's `token_env`); check
  `farmy keys` is not `locked` or `provider failed`, and that the provider has that name. Do not
  `/login` inside: it expires.
- **A subscription is billed per token**: the container has `ANTHROPIC_API_KEY` or
  `ANTHROPIC_BASE_URL` set, which outrank the login. In subscription mode farmy gives neither;
  look for them in `services/<name>.env` or the definition's `env:`.
- **Claude's sessions from another service show up**: they cannot, each service has its own
  `<name>-agents` volume for its transcripts; only the login is shared, on `farmy-shared`.

## Secrets

- **`the git route 'github' for github.com has no secret (locked) — public repositories only on that
  host`**: `GITHUB_TOKEN` was not given; until it is, the broker forwards git without credentials, so
  only public repositories clone. Without a
  `secrets:` section the shim asks for it on this machine: it was in none of the sources (a command
  in `FARMY_UNLOCK_COMMAND`, the Keychain or the secret service under `farmy/GITHUB_TOKEN`, or the
  prefix in `FARMY_SECRET_PREFIX`) and there was no terminal to ask on; the shim named it on stderr.
  Store it (credentials.md, "Where the secrets come from: this machine"), or run the command in a
  terminal and type it; then `farmy keys reload`. Once given, the control container holds it until
  `farmy lock` or a restart of the container; a changed token: `farmy lock`, then `farmy keys reload`. With a provider, `locked` means one of the values
  under `unlock:` was not given. A locked keychain over ssh is unlocked once by the shim, on the
  terminal.
- **`… has no secret (missing)`**: the provider did not return the secret: with Infisical, it must
  exist under that name in the project and environment given.
- **`[shop] the clone failed: fatal: Authentication failed …` and `github.com refused the secret
  GITHUB_TOKEN of the git route 'github'`**: the host turned the token down: expired, revoked, or
  without access to the repository (a fine-grained GitHub token needs the repository and "Contents").
  Make a new one, store it where the old one was, `farmy keys reload`, `farmy restart shop`.
- **`farmy: the secret service answers with an error, so it is not asked again`**: `secret-tool` is
  installed but no secret service answers (no D-Bus session on a headless host, or a locked
  collection, which cannot be unlocked from a shell). Every value is asked for at the prompt instead;
  on a headless host, `FARMY_UNLOCK_COMMAND` (`pass show "farmy/$1"`) is the store that works.
- **`the secrets provider bin/provider failed (exit 3) — run it yourself to see why`**: farmy
  never shows a provider's output while it loads. `farmy keys --why` runs the provider once, as a
  load would (the unlocking values from the shim, the egress node first), and prints how it ended,
  which secrets it answered and its stderr, with every secret and unlocking value replaced by
  `[redacted]`; it loads nothing.
- **`did not answer in the protocol`**: the provider printed something that is not the JSON of
  FORMATS.md.
- **`the keys broker could not be loaded`**: `farmy keys reload shop` tries again; `farmy logs shop`
  shows the broker's side.
- **SSH: `Permission denied (publickey)`** inside the container: the `auth: ssh` route is not loaded
  (`farmy keys`), or the key is not registered on the git host for that repository. The app sees
  `SSH_AUTH_SOCK=/run/farmy-keys/agent.sock`; `ssh-add -l` there lists the key's fingerprint when the
  broker holds it.
- **`the SSH agent could not take the key`** in `farmy logs shop`: the value is not an unencrypted
  OpenSSH private key. When it says the value looks base64-encoded, add `encoding: base64` to the
  route. `farmy keys --why` shows what the provider answered (redacted).
- **`not loaded (farmy keys reload)`**: the keys container was made anew or restarted and lost what
  it held; `farmy keys reload shop`.
- **A service clone fails** (`farmy start` names
  the line that names the cause, `Permission denied (publickey)` for a key the host does not know,
  `Error connecting to agent` when the broker held no key; the Git helper has already tried four
  times over about thirty seconds when the cause may pass, such as `General SOCKS server failure`
  right after the egress node was made anew): the git route for
  that host is not loaded (or there is none: `no git route for codeberg.org`), or the token lacks
  access. `farmy keys` for the state, `farmy keys reload shop`, then
  `farmy restart shop`.
- **`keys: WARN git answered 401`** in the logs: the token is expired, revoked or without access
  to that repository. Fix it at the source, then `farmy keys reload shop`.

## Mesh egress

- **`egress: this node is not registered on the mesh yet`** with a URL: open it, register the node
  on the control server; `farmy start` waits `join_timeout` and goes on. The next start says
  nothing: the state is on the volume `farmy-egress`. `farmy status` shows the URL again.
- **`egress.authkey names X, which is not under secrets.unlock`**: the auth key is an unlocking
  value, obtained by the shim; list it under `secrets.unlock` and store it where the others are.
- **The provider fails behind the mesh**: `farmy status` shows whether the node is registered;
  the provider runs with `HTTPS_PROXY` set, and the Infisical CLI honours it.
- **`lookup <name> on 127.0.0.11:53: no such host`** in the node's log: the node runs in userspace
  mode (`farmy status` says so), where only names under the tailnet's suffix resolve. Give the
  Docker daemon `/dev/net/tun` and let the container have `NET_ADMIN`, then `docker rm -f
  farmy-egress` and `farmy start <name>`.
- **`Could not resolve proxy: farmy-egress`**: a container that is not on the `farmy` network. The
  shim puts the control container there (and attaches one from an older farmy); the app container
  and, with `egress:`, the fragment's services are there too. `farmy restart <name>` for a service
  made before.
- **`ssh: not found` in a clone**: an app image from before the toolbox installed
  `openssh-client`; `farmy rebuild <name>`.
- **A clone fails while the node is unregistered**: the Git helper goes through the
  proxy for SSH hosts (`core.sshCommand`); register the node, then `farmy restart <name>`.

## Building

- **`couldn't clone https://github.com/acme/toolkit.git to read its Dockerfile`**: the git route's
  secret for that host (`farmy keys`), or `repo:` / `branch:` in the definition.
- **`build_files: 'Gemfile.lock' is not in acme/toolkit`**: a file the stage COPYs that is not
  in the repository on that branch.
- **`build_files: 'Gemfile.lock' points outside the repository (a link to ../.env)`**: the file is a link
  committed in the repository that leads above its root, to an absolute path or to nothing. farmy reads
  build files from the committed tree only and follows links only inside it; commit the file itself, or a
  link to a file in the repository. The same holds for `dockerfile:`.
- **`build_files: '../.env' is not a relative path inside the repository`**: `dockerfile:` and every
  `build_files` entry name a path inside the repository: no leading `/`, no `..` part, not empty, not
  starting with `-`. Fix the entry in the service file the message names.
- **`the git container that read … handed its files over cut short`**: the git container clones the branch
  into its own filesystem and hands the build files to farmy on its output, which farmy (as you) writes
  into `.work/<name>/ctx`; the output ended early (the container was stopped, or Docker failed). Run the
  command again.
- **`the toolbox did not build on ruby:3.4-alpine`**: `install.sh` needs apt or apk in the image;
  anything else needs a `toolbox/` of your own. The build's output is above the message.
- **`farmy toolbox: x has no install line for an apk base`**: the catalogue entry has no apk line
  (Cursor's installer is glibc-only); use a Debian image, or override `install` under `agents:`.
- **`agents: 'x' is not in the catalogue`**: a list under `agents:` names catalogue entries; an
  agent of your own goes under `agents:` as a map with its fields (`farmy agents` lists both).

## Running

- **`shop is already running`**: `start` leaves a running service alone. `farmy restart shop`
  applies a changed definition; `status` tells you when one changed.
- **`[shop] setup failed at: bin/setup --skip-server`**: the containers stay up; `farmy ssh shop` to look,
  then `farmy run shop setup` or `farmy restart shop`. A `db:prepare` that cannot reach Postgres means
  the fragment's `postgres` has no `healthcheck:`: with one, the app container waits for it.
- **`[shop] setup did not finish within 30m and was stopped`**: the setup command never ends. A Rails
  `bin/setup` starts the development server unless it gets `--skip-server`; a watcher or a server
  belongs under `start`, not `setup`. A slow but honest setup can get more time with
  `setup_timeout: 1h` in `farmy.yml`.
- **`shop is not running — farmy start shop`**: `run`, `ssh` and the session's commands need the app
  container up.
- **`[shop] note: the toolbox changed since this container was made`**: `farmy rebuild shop`.
- **Port already allocated**: another process on the host holds a port of the block; find it
  (`lsof -iTCP:3100 -sTCP:LISTEN` on the host) or give the service another block.
- **The knowledge container is missing**: `knowledge: false`, or its image failed to build (a
  note at `start`); `farmy stop` then `farmy start shop` builds it again.

## Starting over

- `farmy restart shop`: containers anew, volumes kept.
- `farmy rebuild shop`: images without cache, then the same.
- `farmy destroy shop`: containers and volumes gone, the definition stays.
- `rm -rf .work`: farmy's state; the next `start` writes it again.
- `farmy update`: the control image and container anew, when the checkout changed.
