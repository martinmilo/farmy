# farmy

farmy runs one set of containers per repository: an app container with the repository cloned
inside and the tools a developer or an agent needs, whatever runs next to it (Postgres, Redis, in
plain compose), and a small keys broker that holds the secrets so the app container never does.
An agent such as Claude Code runs inside the container; the secrets stay outside it. A persistent
session (a TUI in tmux) shows every service and lets you start, stop, open a shell or run the
service's own commands, from any terminal that can reach the machine.

## Requirement

Docker and a POSIX shell. Farmy itself runs in a container; the host installs only a small shell shim.

## Install

Download the [install script](https://github.com/martinmilo/farmy/releases/download/v0.1.0/install)
and [SHA256SUMS](https://github.com/martinmilo/farmy/releases/download/v0.1.0/SHA256SUMS)
from the same GitHub release. Verify the exact downloaded bytes before installing:

```sh
sha256sum --check SHA256SUMS
sh ./install
export PATH="$HOME/.local/bin:$PATH"
```

On macOS, use `shasum -a 256 --check SHA256SUMS`. The default registry is
`ghcr.io/<owner>/farmy`, with the owner configured once in [work/release.yml](work/release.yml).
`FARMY_REGISTRY` can override it. Choose `--to 0.1.0` for an exact release or `--dir` for
another bin directory. The installer retrieves the standalone shim through Docker; it does
not need a host clone or compiler. A failed pull can build the matching GitHub mirror tag's
`work/` context; `FARMY_SOURCE` overrides that source. See
[distribution](work/docs/distribution.md) for installation, release publishing and source builds.

<!-- farmy-public-policy -->
GitHub is a code mirror. Report [issues](https://github.com/martinmilo/farmy/issues) and submit
[pull requests as proposals](https://github.com/martinmilo/farmy/pulls) there. The public Forgejo
repository sits behind a mesh and cannot accept internet issues or contributions.

GitHub pull requests are proposals. Maintainers apply accepted changes in the source repository for the next release and credit contributors in the release notes.
GitHub proposals are not merged into the mirrored branch. Maintainers apply accepted
changes in the source repository, deliver them in the next release, and credit each
contributor in the release notes.
<!-- /farmy-public-policy -->

## The first service

In a folder of your own, the containers folder:

```sh
mkdir ~/containers && cd ~/containers
farmy init                                             # the control image, .env with your Git identity
farmy add https://github.com/acme/shop.git --image ruby:3.4-slim   # writes services/shop.yml
farmy start shop                                       # images, containers, the clone, the setup command
farmy                                                  # the session
```

A definition, `services/shop.yml`, says what the service is:

```yaml
repo: https://github.com/acme/shop.git   # the clone URL; none for a workbench without a repository
image: ruby:3.4-slim                     # an official Debian image; the toolbox is built on it
ports: ["3100:3000"]                     # host:container; the hundred 3100 is in is the service's block
commands:
  setup: bin/setup --skip-server         # runs at every start, once the clone is there
  start: bin/rails server -b 0.0.0.0     # the rest on demand: farmy run shop start, or the session
  test: bin/rails test
mounts:
  bundle: /usr/local/bundle              # kept across restarts, on a volume of the service's own
```

Sidecars go under `compose:` as plain compose services; the full key list and more examples are in
[work/README.md](work/README.md) and [work/FORMATS.md](work/FORMATS.md).

## Secrets

No secret lives in a file or in the app container. Routes in `farmy.yml` name the secrets, a
provider you choose yields them (the environment, Infisical, your own program), and the keys broker
next to each app container adds them on the way out; git and API calls go through it. How it works
and how to set it up: [work/docs/credentials.md](work/docs/credentials.md).

## Egress

Factory agents always enforce restriction to their own API hosts. For interactive app
containers whose agents need WebFetch, use audit in `farmy.yml`:

```yaml
egress:
  restrict: audit
```

Audit keeps the internal network and proxy path, permits destinations and records each new
host and port once per container. The modes are `off`, `audit` and `enforce`. The stronger global
or service setting wins: enforce, then audit, then off. Legacy `true` and `false` remain aliases for
enforce and off. `farmy egress log [service]` shows
readable events; add `--json` for structured output.

## Tools and dotfiles

Select vendor tools and distro packages in `farmy.yml`; service definitions can add either list:

```yaml
tools: [neovim, ripgrep]
packages: [imagemagick]
shell: zsh
shared_data: [nvim]
dotfiles:
  repo: https://git.example.com/dev/dotfiles.git
```

The catalogue pins official Linux amd64/arm64 releases and verifies SHA-256 before installation.
`farmy toolbox list --json` shows the resolved entries; `farmy toolbox bump [tool ...]` updates
`tools.lock` atomically. Each service has a private persistent home. Selected editor share/cache
directories reuse storage partitioned by platform, libc and tool versions.

Dotfiles use one authenticated clone, mounted read-only by apps. An optional repository installer runs
as dev; otherwise dotted files are linked and dotted directories merged, with existing files backed up.
`farmy dotfiles pull` fast-forwards the clone and applies it to every running app, reporting partial
failures and retaining each app's last successful revision. See [toolbox and dotfiles](work/docs/toolbox.md).

## Pipelines and review

A service can define named factory profiles and a pipeline that runs them in order. A review step
publishes its gated draft, then waits for approval of the exact commit and captured configuration.
Revision creates a fresh attempt on the same branch. An optional answering profile handles worker
questions; text-only answers can continue automatically, while test changes require their gate and
review. The session shows the pipeline, current step and immutable comparison link.

Execution limits are service scoped, queued runs start in order, and interrupted pipelines resume
their reserved child. Each gate gets fresh isolated sidecars and data. See
[factory profiles and pipelines](work/docs/factory.md) for configuration, commands and notifications.

## Commands

```
farmy session         the session (the TUI), the same as a bare farmy; --background starts it without attaching
farmy init            prepare the folder: Docker, .env, the list of services
farmy add <url>       write a definition for a repository (--image <image>, --name <name>)
farmy start <name>    start a service, then its setup command
farmy stop [<name>]   stop containers; none named: everything
farmy restart <name>  make the containers anew from the definition as it is now
farmy rebuild <name>  the same, and build the images again from scratch
farmy destroy <name>  remove containers and volumes; asks first
farmy status          every service: state, ports, repository (--json for the session's data)
farmy url <name>      the service's addresses on the host
farmy run <name> …    a named command of the service, or any words, in the checkout
farmy keys            every route and its state; farmy keys reload loads the brokers again; farmy keys --why shows why the provider failed
farmy toolbox list --json   resolved vendor tools and pins; farmy toolbox bump [tool ...] updates tools.lock
farmy dotfiles pull   update the shared clone and apply dotfiles to running apps
farmy egress log [service] [--json]   denied destinations and audit observations; farmy egress allow <host> [--service <name>] adds a destination without restarting containers
farmy lock            forget the values the control container holds; the next start asks this machine again
farmy factory start <name> --task …   an agent works on a run of its own until the tests pass; farmy factory list, show, log, cancel
farmy factory pipeline start <service> <pipeline> --task … [--wait]   run profiles with pinned approval and question handoffs
farmy factory approve <id>   approve the exact gated draft; farmy factory revise <id> <text|file> requests another attempt
farmy agents          every agent: on or off, its mode, how to log in without a browser
farmy logs <name>     follow the containers' logs
farmy ssh <name>      a shell in the app container, as the dev user
farmy update          pull the selected release images and replace the shim; --to <version> selects an exact release
farmy help            the usage
farmy --version       the version and the build hash
```

## Guides

- [work/docs/getting-started.md](work/docs/getting-started.md): from a machine with Docker to a running service.
- [work/docs/distribution.md](work/docs/distribution.md): install, update, versions and publishing to your registry.
- [work/docs/troubleshooting.md](work/docs/troubleshooting.md): every refusal and what to do.
- [work/docs/architecture.md](work/docs/architecture.md): images, containers, volumes, what farmy writes.
- [work/docs/credentials.md](work/docs/credentials.md): keys, secrets, the broker, Claude Code inside.
- [work/docs/farmy-mcp.md](work/docs/farmy-mcp.md): what an agent inside a container can ask.
- [work/docs/factory.md](work/docs/factory.md): an agent in a loop until a separate test run passes.
- [work/docs/toolbox.md](work/docs/toolbox.md): verified tools, private homes, selected shared data and dotfiles.
- [work/docs/mesh-egress.md](work/docs/mesh-egress.md): one node on your mesh, a proxy for every container.
- [work/docs/editor-integration.md](work/docs/editor-integration.md): editors and the containers.
- [work/docs/worked-example.md](work/docs/worked-example.md): a Mac with the Keychain, Infisical and a Headscale mesh, step by step.

## Updating

```sh
farmy update                # latest stable release, or the current folder's pin
farmy update --to 0.1.0      # choose an exact release
```

To pin a containers folder, add `farmy: 0.1.0` to its `farmy.yml`. A mismatch gives the update
command to fix it. Both `farmy.yml` and service definitions accept `format: 1`; omitting it
also means format 1. Status identifies toolboxes built by older farmy versions and names
the `farmy rebuild <name>` command to refresh each one.

## Contributing

The repository is built by two agents kept apart on purpose; [CONTRIBUTING.md](CONTRIBUTING.md)
explains the layout, how to run the suite and where decisions are recorded.

## Licence

MIT, see `LICENSE`.
