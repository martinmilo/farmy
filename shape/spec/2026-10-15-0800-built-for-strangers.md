# 2026-10-15 08:00 — Built for strangers

Every record since the first run was shaped against one setup: macOS with Docker Desktop or OrbStack,
the Keychain, Infisical with universal auth, a Headscale mesh, a git host with SSH on a non-standard
port, keys stored base64 in the secrets manager. The owner asked for an audit of every decision from
those rounds: is it generic, with that setup as one instance, or is it that setup's? Then a second
person walked end to end, and whatever that person hits that is harder than the macOS path fixed here.

**The second person** ("the stranger" below): a Linux host with Docker Engine, repositories on GitHub
over https with a token route (never exercised so far), Claude Code with an API key, no mesh, no
secrets manager: the values come from the Linux secret service, or from a plain prompt.

The bar is the one the factory's definition already meets (its draft, kept for the factory record):
the default fits any repository, the stricter options are for the layouts that need them, and farmy
knows no folder names. Applied here: the default fits any host, the owner's setup is one worked
example, and farmy knows no product names it does not have to.

## 1. The audit

"Owner's setup" is what drove the decision. "Generic form" is what the decision is once that setup is
taken out. "Gap" is what a stranger still meets; **bold** gaps are fixed in this record (section 3),
the rest are in section 5 for the owner to decide.

| Feature | Owner's setup that drove it | Generic form | Gap |
|---|---|---|---|
| Unlock sources: `FARMY_UNLOCK_COMMAND`, else Keychain, else secret service, else prompt (2100) | macOS Keychain | Four equivalent sources, chosen by what is on the PATH; the Keychain is one | **A secret service that cannot be reached (no D-Bus session on a headless host, a locked collection) is asked again for every name, with the same error each time** (D5). A prompted value is asked again at every `start` (5.1) |
| `FARMY_SECRET_PREFIX`, default `farmy/` (2100, 2600) | One Keychain shared with other tools | One prefix for both stores, from the environment or `.env` | None |
| Old lookup forms `-s farmy -a NAME`, `service farmy account NAME` (2100) | Entries the owner made before 2100 | Compatibility for entries nobody else has | Dead weight for a stranger: an extra store call per miss (5.2) |
| Locked Keychain: `security unlock-keychain` once (2100) | A Mac reached over SSH | Platform-specific handling of a locked store | None for the stranger; D5 gives the secret service the same once-only rule |
| Values travel as `NAME:base64=…` (2900) | A multi-line SSH key | Byte for byte for any value | None |
| Providers: a program speaking JSON (0600), resolved in the containers folder then farmy's (1300) | Infisical | The protocol; `providers/env` and `providers/infisical` are two instances | **Without `secrets.provider` every route reads `off` and a value given on stdin is ignored: the stranger has to write `provider: [providers/env]` and list every route's secret again under `unlock:`** (D2) |
| Infisical provider, token mode (`INFISICAL_TOKEN` under `unlock:`) (1300) | Infisical service token | One instance of a provider | None (it is the provider's own business) |
| Infisical provider, universal auth (`--client-id-from`, `--client-secret-from`, `--domain`) (2100) | Infisical machine identity, self-hosted domain | One instance of a provider | None |
| The Infisical CLI in the control image (1300) | `providers/infisical` needs it | One third-party CLI in every control image | Every `farmy init` fetches it from Infisical's package repository, which a stranger never uses (5.3) |
| Route `encoding: base64`; an SSH value that decodes to a key is `rejected` (2900) | Keys stored base64 in the secrets manager | Any provider may store a value encoded; the hint fires on what the value is, not where it came from | None; the guides frame it as one case of "how your manager stores it" (D6) |
| Egress in kernel mode, userspace fallback (2700) | Headscale extra records and split DNS | Tailscale with `/dev/net/tun` and `NET_ADMIN`; a daemon that refuses them falls back with a note | None for the stranger (no `egress:`: nothing of it anywhere, tested). Docker Engine on Linux has the device, so kernel mode is the likely path there |
| Egress registration: auth key from the unlock sources, else URL from the log (2300, 2400) | Headscale with `register` by URL | Tailscale's own control server or `tailscale.login_server` | Tailscale only (5.10) |
| The control-server lessons in the egress guide: tag ownership, restart to recompute peers, `tailscale ping` is no ACL test (2700, 3200) | Headscale | Partly Tailscale's (tags, ACLs), partly Headscale's (restart) | **The guide reads as if every mesh were Headscale** (D6: the Headscale lessons move to the worked example) |
| `FARMY_EGRESS_PROXY` (2600) | A test handle for the CONNECT proxy | Any proxy address, but only with `egress:` | A stranger behind a plain corporate proxy cannot use it without a mesh (5.4) |
| SSH route keeps the upstream's user and port; `DEV_GIT_SSH_ROUTES` insteadOf (3100) | A git host with SSH on port 2222 | Any SSH host, any port, any user | None |
| Token route, `git: true`, `DEV_GIT_ROUTES` insteadOf to the broker (0600, 1500) | Designed first, never run: the owner switched to SSH (0700) | GitHub, Codeberg, any https git host | **Never exercised: the fake answered `ok` to every https clone, so a clone through a route without its secret looked fine. The warning says "public repositories only" while the broker answers 503 for everything on that host. A token the host refuses ends in git's last two lines** (D3, D4) |
| `user: x-access-token` on token routes (1500) | GitHub's documented user for app tokens | Basic auth with a fixed user | GitHub accepts any user with a token; other hosts are not verified (5.7) |
| The clone reason's cause list (3000, 3200) | SSH failures on the owner's run | The first line that names a cause | **Only SSH and network causes are listed; https authentication is not** (D4) |
| Agents catalogue, default `{claude: {}}`, mode `subscription` (2200) | A Claude subscription | A catalogue of six; Claude on by default, logged in inside the container, no secret needed | Claude is installed in every image unless switched off (5.9). Api-key mode needs a route with the agent's upstream, which is generic |
| The shared login volume `farmy-shared` (1700, 2200, 3200) | One subscription across many containers | One login per tool for every container | One login is all or nothing across repositories of different trust (5.8) |
| `docs/first-run.md` (1400 to 3200) | The owner's run on the Mini, step by step | A script of the macOS + Infisical + Headscale + SSH path | **It is the only walkthrough with the secrets and the mesh in it, and it is the owner's path** (D6: it becomes the worked example) |
| `farmy.example.yml`: provider `providers/infisical` first, route `git`/`GIT_TOKEN`, an SSH and a Codeberg route commented, `anthropic` with `expose`, `placeholder`, `services: [shop]` (0600, 1500, FORMATS) | The owner's providers and routes | An example to copy | **Copied as it is, it asks Infisical for everything; `services: [shop]` names a sample service** (D6) |
| Defaults in `farmy.yml`: `knowledge: true`, `setup_timeout: 30m`, `egress.join_timeout: 10m` | Mission control, Rails setup, a human registering a node | Values two real projects would share | None |
| Other defaults: ports block from 3100, container port 3000 assumed, uid 1001, `BASE` `debian:bookworm-slim`, provider limits 30 s / 1 MB, broker 9181, knowledge 9190, proxy 1055 | Rails and Vite apps, the Debian rule | Neutral numbers | Ports are published on every interface (5.6) |
| The control container runs as root, the containers folder bind-mounted at its host path (0400, 1400) | Docker Desktop and OrbStack map file ownership to the host user | One folder seen at the same path in and out | **On Docker Engine on Linux every file farmy writes there (`.env`, `services/<name>.yml` from `add` and the port write-back, `.work/`) belongs to root on the host** (D1) |
| The Docker socket is `/var/run/docker.sock` (0400) | Docker Desktop and OrbStack provide it | The rootful default on every platform | Rootless Docker (`DOCKER_HOST=unix:///run/user/…`) is not found (5.5) |
| `TZ` from the host, else where `/etc/localtime` points (1800) | macOS | Works on Linux the same way | None |
| `host.docker.internal` via `extra_hosts: host-gateway` (1200) | Docker Desktop resolves it anyway | Docker Engine needs the `extra_hosts` line, which farmy writes | None |
| `LAN_HOST` (1500) | `mini.local` on the owner's LAN | Any name | None |

## 2. The stranger, end to end

Walked through the fake docker and the shim, then once against a real Docker:

1. Docker Engine, the user in the `docker` group; `git clone` farmy, the shim on the PATH. **Same as
   macOS.**
2. `farmy init`: `.env` from the host's git identity. **Same.** On Docker Engine `.env` is root's
   (D1).
3. `farmy add https://github.com/acme/shop.git --image ruby:3.4-slim`. **Same**; the definition is
   root's (D1), and the stranger cannot edit it without `sudo`.
4. `farmy.yml`: a GitHub token route, an Anthropic route, `agents: {claude: {mode: api-key}}`. The
   stranger has no secrets manager. Today they must add `secrets: {provider: [providers/env], unlock:
   [GITHUB_TOKEN, ANTHROPIC_API_KEY]}` or every route reads `off` (D2). The owner's path writes one
   provider line and one unlock name.
5. The values: `secret-tool store …` once, or a prompt at every start. On a headless host the secret
   service errors for every name (D5).
6. `farmy start shop`: the broker is loaded before the clone (3000), the clone goes through the
   route. A wrong token ends start with git's last two lines (D4); a missing one says "public
   repositories only" and then fails with a 503 (D3).
7. Claude in api-key mode: `ANTHROPIC_BASE_URL` and the placeholder from the route. **Same as any
   agent**, tested.
8. No mesh: nothing of egress anywhere. **Tested already.**
9. The guides: getting started, the credentials guide and the example file lead with the Keychain,
   Infisical and SSH (D6).

## 3. Decided

**D1. What farmy writes in the containers folder is the folder owner's.** Every file and folder farmy
creates or rewrites under the containers folder (`.env`, `services/<name>.yml` from `add` and from the
port write-back, everything under `.work/`) is owned by the owner of the containers folder (its uid and
gid as the control container sees them), whatever user farmy runs as. On Docker Desktop and OrbStack
this held already; on Docker Engine it did not. How is the worker's choice (write as that user, or
hand each file over after writing it); the control container may stay root. Only the integration test
can see it, since the suite runs farmy as the folder's owner.

**D2. Without a provider, the host gives the routes' secrets.** When `farmy.yml` has no
`secrets.provider`, the secrets the routes name are obtained on the host like unlocking values (the
command, the Keychain, the secret service, a prompt) and farmy loads them into the brokers as they
come. `farmy unlock-names` then prints the names under `secrets.unlock` followed by the secret of
every route under `keys:`, once each, in file order. A route whose secret was not given reads
`locked`; the state `off` is gone. `providers/env` with names under `unlock:` stays and does the same
explicitly. An agent's `token_env` secret still needs a provider, so that the prompt never asks for
something optional at every start.

**D3. A git route without its secret is said as it is.** The broker answers 503 for a route it holds
no secret for, so nothing on that host clones through it, public or not. The warning at start says so
and names `farmy keys reload` (not "public repositories only", which stays for a host with no git
route at all). A clone that fails through a git route whose secret is not loaded names the route, its
state (`locked`, `missing`, `provider failed`, `rejected …`) and `farmy keys reload`.

**D4. A refused token is named as one.** The cause list of the clone reason gains `Authentication
failed`, `could not read Username`, `returned error: 401`, `returned error: 403`. When the repository
goes through a token route whose secret is loaded and the reason is one of these, farmy says the host
refused the route's secret, naming the route and the secret's name. The entrypoint clones with
`GIT_TERMINAL_PROMPT=0` (git must not wait for a user name) and retries `returned error: 503` (the
broker not loaded yet) like the other reasons that may pass. The fake now plays the broker: an app
container whose repository goes through a token route clones only when its keys container was loaded
with that route's secret since it last started, else its marker reads `failed` with git's 503 line.

**D5. A secret service that answers with an error is asked once.** When `secret-tool` fails with a
message on stderr (a locked collection, no D-Bus session), the shim shows the message once, asks the
secret service nothing more for this command, and asks for every value with the prompt instead (left
out without a terminal). The Keychain's once-only unlock stays as it is.

**D6. The guides lead with the stranger.**
- `docs/getting-started.md` in this order: Docker Engine on Linux (Docker Desktop and OrbStack after
  it), `init`, `add` with a GitHub https URL, the token route (`auth: basic`), the values (a prompt,
  then `secret-tool store`, then the Keychain), `start`, Claude with an API key, and only then the
  other setups: an SSH route (`auth: ssh`), a secrets manager, a mesh (`egress:`). It ends by pointing
  at the worked example, the last thing it names.
- `docs/credentials.md` keeps its rule first ("never stores a secret on disk"), then: routes with a
  token before the SSH route, the prompt and the secret service before the Keychain, no provider
  before providers, `providers/env`, then `providers/infisical` and a provider of your own. Values a
  secrets manager stores base64 are one paragraph under the providers, not an Infisical story.
- `docs/mesh-egress.md`: Tailscale's own control server first, a control server of your own
  (`tailscale.login_server`) after; Headscale is named as one example of the latter; its lessons
  (users and tags, the restart) move to the worked example.
- **`docs/worked-example.md`** (new): the owner's setup as one example with generic names: macOS,
  the Keychain, Infisical with universal auth and its own domain, a Headscale mesh, a git host with
  SSH on port 2222, keys stored base64. It takes the verified steps of `docs/first-run.md`, which
  goes.
- **`farmy.example.yml`**, copied as `farmy.yml`, works for the stranger: no `secrets:` (a provider is
  shown commented, `providers/env` first, then `providers/infisical`), the first route `github`
  (`GITHUB_TOKEN`, `https://github.com`, `auth: basic`), an `anthropic` route with no `services:`, the
  SSH route and a second host commented, `egress:` commented at the end, `# mode: api-key` shown
  under `agents.claude`.
- The README's guide list gets the worked example as its last line. FORMATS' examples follow: the
  route `github` with `GITHUB_TOKEN`, the env provider first.

## 4. Tests altered

`keys_test.rb`: "a provider that fails switches its routes off…" and "a provider that answers with the
protocol's error form…"; `providers_test.rb`: "providers/infisical with an identity Infisical
rejects…". Their service `shop` is on github.com behind the `git` route of the provider that failed;
with the fake playing the broker's 503 (D4), the clone now fails and start exits 1. They assert exit 1
instead of exit 0; the first is renamed "… and start goes on to the containers" and still asserts the
app container is running. Their point (the provider's failure is reported without its output, the
routes are not loaded) is unchanged.

## 5. Not fixed, for the owner to decide

1. **A prompted value is asked at every `start`, `restart`, `rebuild` and `keys reload`.** Keeping it
   between commands needs a long-lived agent in the control container (left out in 0600 and 2100):
   a value in memory that any process able to `docker exec` into the control container could ask
   for. Today: use the secret service or `FARMY_UNLOCK_COMMAND` (`pass`), which the guide says.
2. **The old lookup forms** (`-s farmy -a NAME`, `service farmy account NAME`) exist for entries made
   before 2100, which only the owner has. Dropping them before publishing removes a call per miss and
   a paragraph of the guide; it breaks the owner's Keychain entries until they are renamed.
3. **The Infisical CLI in every control image.** Every `farmy init` and `update` fetches it from
   Infisical's package repository, so a stranger's first build depends on a service they do not use,
   and fails when it cannot be reached. Options: install it best effort (the provider already answers
   the error form without it), or only when `farmy.yml` names `providers/infisical`.
4. **A proxy without a mesh.** A host behind a corporate HTTP proxy cannot give the containers that
   proxy without running a Tailscale node: `FARMY_EGRESS_PROXY` only applies with `egress:`. Proposal:
   `egress: {proxy: host:port}` with no `tailscale:`, no node, the same variables.
5. **Rootless Docker.** The shim mounts `/var/run/docker.sock`; with `DOCKER_HOST=unix:///run/user/…`
   nothing is there. Mounting the path `DOCKER_HOST` names would fix it on Linux; on macOS the socket
   path is the VM's, so the rule needs care. File ownership under rootless (D1) is a second question.
6. **Ports are published on every interface.** `3100:3000` binds 0.0.0.0. On a laptop or behind a
   LAN that is what `LAN_HOST` wants; on a Linux server with a public address it is the internet, and
   Docker's rules pass by `ufw`. Option: bind `127.0.0.1` unless `LAN_HOST` is set.
7. **`user: x-access-token`** is GitHub's word; GitHub accepts any user with a token. Codeberg,
   Forgejo, Gitea and GitLab are not verified with it. The example keeps it on the GitHub route only.
8. **One shared login for every container.** `farmy-shared` gives each tool one login across all
   repositories; a stranger mixing repositories of different trust has no per-service opt-out except
   api-key mode or `off`.
9. **Claude is on by default** and installed in every image. A stranger who uses another agent
   writes `agents: {codex: {}}`; one who uses none writes `agents: []`. Changing the default changes
   what a bare `farmy start` gives the owner.
10. **The mesh is Tailscale only.** `egress.tailscale` leaves room for another kind; none is planned.
11. **A git route without its secret blocks public repositories on its host** (D3 makes it visible).
    The broker could forward such a request without credentials instead of 503; that is a change to
    the broker's contract (0600: "a route not loaded answers 503").
12. **The persona's integration test has not run here**: this machine has no Docker. It is written
    for Docker Engine on Linux and runs on any Docker; D1 is only visible on Docker Engine.

## FORMATS.md

- Keys and secrets: no provider (D2), the state list without `off`, the example's route `github`
  and `GITHUB_TOKEN`, the env provider first.
- Unlocking: `farmy unlock-names` with the routes' secrets; the secret service asked once (D5).
- The folder farmy runs in: ownership (D1).
- The clone marker: the new causes, the refused route's secret, `GIT_TERMINAL_PROMPT=0`, 503 retried
  (D3, D4).
- The fakes: the broker's 503 for a token route; `secret-tool` that cannot be reached; `farmy
  unlock-names` with the routes' secrets.

## Scenario list

stranger_test.rb (new: Linux, GitHub over https with a token, Claude with an API key, no mesh, no
secrets manager)
- without a provider farmy unlock-names lists the routes' secrets, so the host is asked for each
- the shim obtains the GitHub token and the API key from the secret service and hands both to farmy
- start loads both secrets into the broker before the clone, and the repository clones through the token route
- after start farmy keys reads both routes loaded
- Claude in api-key mode from farmy.yml gets the base URL and the placeholder from the anthropic route, and no token
- with no value given farmy keys reads both routes locked, not off
- with no value given start ends at the clone, naming the route's state and farmy keys reload, and never says public repositories
- a token GitHub refuses ends start saying the host refused the route's secret, by name
- the shipped farmy.example.yml, copied as farmy.yml, starts a GitHub service with the two values on stdin

unlock_test.rb
- a secret service that cannot be reached is named once, asked nothing more, and every value is asked for instead

docs_test.rb
- getting started leads with Docker Engine, the token route, the prompt and no mesh, and points at the worked example last
- the credentials guide shows the token route before the SSH route, and the prompt and the secret service before the Keychain
- the worked example carries the macOS, Infisical, Headscale and SSH-port setup with example.com names, and first-run.md is gone

keys_test.rb, providers_test.rb (altered, section 4)

integration_test.rb
- a stranger's start: the token route clones from an http git host through the broker, the values come from the secret service, Claude is in api-key mode, nothing of egress runs, and every file farmy wrote is the user's
