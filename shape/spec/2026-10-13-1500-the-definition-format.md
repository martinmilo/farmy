# 2026-10-13 15:00 — The definition format

Before the first run goes on, the definition format is settled: what a service says about its
repository and its ports, how it is added, and the words used for the git host. Five decisions,
one record, nothing else in it.

## 1. `repo:` is a clone URL; the git host is in the routes

- **`repo:` is always a full clone URL** (`https://github.com/acme/shop.git`,
  `ssh://git@github.com/acme/shop.git`, `git@github.com:acme/shop.git`, `file:///…`) or `none`
  (a workbench). A definition without `repo:` is refused naming `repo:`; a `repo:` that is not a
  clone URL (`acme/shop`) is refused as such. Nothing is named relative to anything.
- **`.env` holds the Git identity and `LAN_HOST`, nothing else.** `FORGE_URL`, `FORGE_OWNER` and
  `FORGE_SSH_USER` are gone from `.env`, `.env.example`, `init` and the docs. A key farmy does
  not read is ignored.
- **Git routes are matched by host.** A route with `git: true` applies to the repositories whose
  clone URL has the host of the route's `upstream`. There may be several (`github`, `codeberg`,
  …); the example route is named `git`, with the secret `GIT_TOKEN`. Every granted git route is
  rewritten in the app container's git, whatever the service's own host; the host match decides
  the warning ("no git route for github.com with a secret: a private repository will not
  clone"), the transport, and the check that git reaches the host through the broker.
- **An SSH git route** names its host in `upstream: ssh://git@github.com` (the user before `@`;
  `git` when there is none). A repository on that host whose `repo:` is an `https://` URL is
  cloned over SSH, `ssh://<user>@<host>/<path>`: the pasted URL stays, the route decides the
  transport. An `ssh://` or `git@host:` URL is taken as it is.
- **The word "forge" leaves the repository.** Docs, messages, tests and the kit say "git host";
  the examples use github.com and codeberg.org. The spec records are history and keep their
  words.

## 2. `ports:` lives in the definition and is optional

- **`ports:` is a list of `host:container` pairs**, as compose writes them:
  `ports: ["3100:3000"]`, `ports: ["3200:5173", "3201:24678"]`. The first pair is the app's
  address. `ports.yml` is gone; one still in the folder is refused by name, so nobody wonders
  why it is ignored.
- **A service owns the block of one hundred its host ports lie in**: `3100:3000` puts the
  service in `3100-3199`, and `${FARMY_PORT_<n>}` in its fragment is `3100 + n`. All of a
  service's host ports lie in one block, and two services never share a block; both are refused
  naming the block. `status` shows every service's block, `-` for none.
- **Absent: nothing published.** No address, `farmy url` prints nothing, `status` shows `-`.
- **Absent but referenced**: when another definition uses `${url:x}` or `${port:x}`, or the
  service's own fragment uses `${FARMY_PORT_<n>}`, farmy takes the next free block from
  `3100-3199` upward, writes `ports: ["<first port>:3000"]` into that definition and says so on
  stderr, naming the file and that 3000 is the container port it assumed. It happens at `start`
  and `status`, before anything else is done with the definition.

## 3. `farmy add <url> [--image <image>] [--name <name>]`

Writes `services/<name>.yml` with `repo: <url>` and `image: <image>`, the name being the last
part of the URL without `.git`, and prints what to do next (`farmy start <name>`). On a
terminal a missing `--image` is asked for; without one it is a mistake in the command line,
named by `--image`. A definition that exists already is not touched: refused by file name.
`add` needs neither Docker nor `.env`.

## 4. The control image is rebuilt when its inputs change

The shim built `farmy:local` only when it was missing, so a changed `Dockerfile` ran stale until
`docker rmi`. Now the image carries the label `farmy.hash`, a content hash of the control
image's build inputs; `farmy init` and `farmy update` rebuild when the label differs from the
hash of what is there now (or the image is missing). The other commands trust the image.

## 5. Sample names stay generic

The sample service `hub` becomes `shop` everywhere: fixtures, tests, FORMATS, docs. `notes` and
`toolkit` stay. The git host in the examples is github.com; the test's own host is a folder of
bare repositories reached through `file://` URLs written into `repo:`.

## Not decided here

- `farmy add` learning the image from the repository (a `.ruby-version`, a `package.json`).
- Renaming a service, or `farmy remove`.

## FORMATS.md

Rewritten where it touches these: the folder layout, `.env`, the definition (`repo:`, `ports:`),
keys (`git`, hosts, SSH), the knowledge container (no `ports.yml`), the commands (`add`,
`update`), the exit table, `status`, the git host in the tests, `DEV_GIT_ROUTES`.

## Tests

New: `ports_test.rb`, `add_test.rb`; two shim tests. Changed: every test that named `hub`, a
`FORGE_*` key, the `forge` route, `ports.yml` or an `owner/name` repository. The kit: `settings`
without the host keys, `remote_repository`/`remote_url`/`define_from_remote` in place of the
forge helpers, `docker` and `assert_builds` for the shim.

## Scenario list

repository_test.rb
- a definition names its repository by a full clone URL and status shows it
- a definition without repo is refused naming repo:
- a repo that is not a clone URL is refused naming it

ports_test.rb
- a service with ports publishes the first host port on the first container port
- a service's ports become its block, and ${FARMY_PORT_n} in its fragment is the n-th port of it
- a definition without ports publishes nothing, and url prints nothing
- a service referred to with ${url:x} and without ports is given the next free block, written into its definition
- a service whose own fragment uses ${FARMY_PORT_n} and has no ports is given a block the same way
- two services whose host ports lie in the same block are refused naming the block
- a service whose host ports lie in two blocks is refused
- a ports.yml in the folder is refused by name and ports: is pointed at
- status shows every service's block, and - for a service without ports

add_test.rb
- add writes a definition named after the repository with its URL and image, and says how to start it
- add --name writes the definition under that name
- add without --image and without a terminal is a mistake in the command line
- add for a service that is defined already is refused by file name and the file is kept
- add without a URL is a mistake in the command line

keys_test.rb (changed and new)
- the git route named git applies to the repositories on its host (renamed from forge)
- with routes for two hosts each app container is given both rewrites, and the warning names the host without one
- with an SSH git route for its host an https repo: is cloned over SSH, and nothing is rewritten

shim_test.rb (new)
- init twice builds the control image once
- init rebuilds the control image when its build inputs changed since it was built

help_test.rb
- the usage lists add

init_test.rb, start_test.rb, status_test.rb, stop_and_destroy_test.rb, compose_test.rb,
knowledge_test.rb, defining_services_test.rb, build_from_repository_test.rb: renamed and rewritten
for shop, clone URLs, ports: and the git host.
