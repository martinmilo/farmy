# Toolbox and dotfiles

The service image supplies its runtime. Farmy's toolbox adds the dev user, Git, shells, configured
agents, selected vendor tools and distro packages. Set `tools: [neovim, ripgrep]` and optionally
`packages: [imagemagick]` in `farmy.yml`; service definitions may add either list. Omitted tools select
none. `tools.yml` ships Neovim, ripgrep, fd, fzf, bat, lazygit, delta and jq with Linux amd64/arm64 pins.
Each build verifies SHA-256 before executing an install recipe. Unsupported architecture/libc combinations
are refused; Neovim and delta currently support Debian-family images only in the shipped catalogue.

`farmy toolbox list --json` includes inactive tools and resolved workspace overrides. A custom entry under
`tool_catalogue` has `version`, `artifacts`, per-family `install` recipes, and optionally `releases` for
GitHub release discovery. Artifact keys are `linux-amd64-glibc`, `linux-arm64-glibc` and their musl
counterparts. Each provides `url`, `sha256`, and `format` (`raw`, `tar.gz`, `tar.xz`, `zip`). Version
changes require complete replacement artifacts; a checksum and URL must be overridden together.

`farmy toolbox bump [tool ...]` downloads stable releases, calculates their checksums, validates published
checksum metadata, and atomically writes `tools.lock`. Without names it updates the active union across
workspace and service definitions. A failed artifact leaves the whole lock unchanged. Keep the lock in
your containers repository. Normal starts/rebuilds use it without rewriting it; status reports newer
shipped pins and the bump command. A manually pinned custom tool needs a release resolver before bumping.

A custom `toolbox/Dockerfile` receives generated `tools.yml`, `packages.txt`, `tools-install.sh` and
`farmy-home.sh`. The managed installer supports `TARGETARCH=amd64|arm64`, `FARMY_BASE_FAMILY=apt|apk`, and
`DESTDIR`; otherwise it detects its image. `ARCHIVE` in a recipe names the verified download. Set
`toolbox: {managed: false}` to opt your custom toolbox out of managed tools and packages.

## Custom toolbox and farmy's entrypoint

`start` and `rebuild` say `custom toolbox: <containers folder>/toolbox` on stderr when they build yours.
Whatever toolbox is built, with or without `managed: false`, farmy's layer comes last: it installs farmy's
own entrypoint (from farmy's installation, never from your folder) at `/usr/local/bin/farmy-entrypoint`
and makes it the image's `ENTRYPOINT`. The image's `farmy.entrypoint.modes` label lists the modes of that
entrypoint. A `toolbox/entrypoint.sh` of yours, or an `ENTRYPOINT` in your Dockerfile, has no effect.
Your image still has to provide what that entrypoint needs: the `dev` user (uid 1001), `gosu` (or
`su-exec`, named in `/usr/local/lib/farmy-drop`), git and curl. Farmy's `toolbox/install.sh` sets all of
that up; copying it into your folder is the easy way. Farmy keeps its own files in the build context
under `farmy-layer/`, so your folder may not have one; your `.dockerignore` cannot exclude it.

Startup logic of your own goes into `toolbox/start.sh`. Farmy's layer installs it as
`/usr/local/lib/farmy/toolbox-start.sh` (executable; with a shebang it runs under that interpreter, without
one under `sh`). Farmy's entrypoint runs it at every container start, as dev, from dev's home folder
(`/home/dev`), after its own startup (volume ownership, Git defaults, agent links, the broker wait,
forwarders) and before the container waits. The repository checkout and `setup` are not guaranteed to have
happened yet. It has to return: start a long-running process in the background. A failure is logged with
its exit status (`docker logs <name>`: `farmy-entrypoint: toolbox start.sh failed with exit status <n>`)
and the container stays up. `farmy rebuild <name>` brings a changed `start.sh` in.

## Private homes and selected shared data

Each service has a persistent private `<service>-home` volume. `shell: sh|bash|zsh` selects dev's installed
login shell; zsh is the default. `farmy ssh` starts that shell interactively.

`shared_data: [nvim]` is the default. Each name shares only `~/.local/share/<name>` and `~/.cache/<name>`;
use `[]` to disable sharing. Storage under `farmy-shared/tool-data` separates architecture, libc and the
full sorted selection of tool versions. Other home files remain private. An existing nonempty selected
directory requires an explicit migration decision; farmy never moves personal data automatically.
Agent logins remain shared by default. `shared_logins: false` keeps them private while exposing only the
shared tool-data and read-only dotfiles subdirectories. Destroying a service keeps shared data and clone.
Factory agents use image binaries with private runtime homes; gates use scratch HOME.

## Applying dotfiles

Set `dotfiles.repo` to a clone URL. Farmy initializes one clone on the remote's default branch through
the existing Git broker routes. Clone publication is atomic, concurrent updates serialize, and updates
are fast-forward only. Dirty checkouts and unexpected repository changes are refused. Apps mount the
clone read-only; only the initialization/update helper writes it. Every app gets that read-only mount, with or
without dotfiles configured, so a read-write shared parent never reaches the clone. A container made
without it (by an older farmy) gets nothing applied: `[<name>] … farmy restart <name>`, exit 1.

Without `dotfiles.install`, farmy links dotted files and recursively merges dotted directories into the
service's private home, excluding Git/forge metadata. Existing files and symlinks move, retaining their
relative paths, to one reported `~/.dotfiles-backup/<unique timestamp>` directory. Correct links do
nothing on reapplication. Unmergeable directory conflicts are refused. Managed shared-data links are
protected during merging.
Farmy's Git defaults live at system scope. A read-only `.gitconfig` link remains owned by the user,
whose identity and ordinary preferences override those defaults. Managed broker URL routes and SSH
proxy transport remain effective, including when a personal rewrite has a more-specific URL prefix.
Installing or pulling dotfiles refreshes those managed routes before service setup.

An optional `dotfiles.install: install.sh` runs that executable with its shebang from the clone root as
dev, with the service's HOME. It runs after shared-data links and before service setup on every restart.
A failure stops startup readiness and reports its cause.

`farmy dotfiles pull` updates the clone and attempts every running service. Successful services record
the new SHA; failed services retain their last applied SHA. A partial application exits 1 and names each
outcome without rolling the clone back. `status --json` includes `dotfiles.revision`, `state` and
`wanted_revision` per service.

Each exec into a running app container for this (the dotfiles/home step as dev, then
`farmy-entrypoint --git-config` as root) is limited to `FARMY_EXEC_TIMEOUT` seconds (default 60). The
limit is applied inside the container with `timeout`, and the `docker exec` client is killed a few
seconds later if it is still running. Either way it is reported as
`[<name>] … timed out after <n>s: <command>`. A failure names its exit status and the last lines of its
stderr. The entrypoint declares its modes in a `# farmy-entrypoint-modes:` line. The toolbox build copies
them into the image's `farmy.entrypoint.modes` label, and farmy runs a mode only when that label names it.
An image built before the label is skipped without any exec:
`[<name>] built by an older farmy: farmy rebuild <name>`. The label comes from farmy's own entrypoint,
which every image gets whatever toolbox it is built with, so the rebuild that message names fixes it.
