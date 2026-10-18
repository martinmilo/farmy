# 2026-10-15 09:00 — Strangers, part two

The owner's decisions on section 5 of "built for strangers" (2026-10-15 08:00). Eight are built here;
three are decided without work. The factory record comes after this one, with its definition and its
protection in the writes/protects/hidden form.

## Decided without work

- **3. The Infisical CLI stays in the control image.** It is one package at build time, not a fetch per
  `init`. Revisit when a published image exists.
- **7. `user: x-access-token` stays for GitHub.** The credentials guide gives the user for other hosts:
  GitLab `oauth2`, Forgejo and Gitea the account's own user name, with the token as the password.
- **10. The mesh is Tailscale only.** An existing proxy is covered by D4.

## Decided and built

**D1. The control container holds the unlocking values for its lifetime.** A holder process in the
control container keeps the values the host gave (the unlocking values, and without a provider the
routes' secrets) in its memory, never on disk. farmy starts it the first time values arrive on its
stdin and hands them over; every later command that runs the provider or loads a broker takes them from
the holder, with or without values on stdin (stdin wins, and what it brings is held from then on).
`farmy unlock-names --missing` prints only the names the holder does not have, and the shim asks the host
for those alone, so the Keychain, the secret service or the prompt is asked once per control container.
`farmy lock` clears the holder (it says so, and the next load asks again). A restart of the control
container ends the holder and so clears it. The factory needs this: a run makes containers anew without
anyone at a terminal.
- The holder listens on a Unix socket, `FARMY_HOLD_SOCKET`, default `/run/farmy/hold.sock`, mode 0600, and
  exits when its socket file is gone (the suite gives each test its own path, removed after the test).
  It holds nothing a file, a docker command line, a container's configuration or farmy's output shows.
- Anything that can `docker exec` into the control container can ask the holder. That is the operator,
  who could read the Docker socket anyway; the guide says so.

**D2. One lookup form.** The shim asks the Keychain for `-s <prefix><NAME>` and the secret service for
`farmy <prefix><NAME>`, nothing else: the old forms (`-s farmy -a NAME`, `service farmy account NAME`)
are gone, before anyone outside has entries in them.

**D3. `egress: {proxy: host:port}`: an existing proxy, no node.** No Tailscale container runs. Every
container farmy starts and the provider get `HTTP_PROXY` and `HTTPS_PROXY` (both cases) as
`http://<host:port>` and the same `NO_PROXY`; no `ALL_PROXY`, since a corporate proxy speaks HTTP. git
over SSH goes through it by HTTP CONNECT (the entrypoint's `ProxyCommand nc -X connect -x <host:port> %h
%p` when `ALL_PROXY` is absent and `HTTPS_PROXY` is set; farmy's own Dockerfile fetch the same). `proxy`
with `authkey` or `tailscale` is refused, naming both. `status` prints `egress  proxy  <host:port>`;
the JSON's `egress` has `state: "proxy"`, `mode: "proxy"`, `proxy: <host:port>`. The guide documents it
as the corporate case.

**D4. The shim finds the Docker socket.** It asks `docker context inspect` for the current endpoint.
On a Linux host a `unix://` endpoint's path is the socket the control container gets, at
`/var/run/docker.sock` inside (rootless Docker: `unix:///run/user/1000/docker.sock`). On macOS the daemon
runs in a VM whose socket is `/var/run/docker.sock` whatever the context says (Docker Desktop, OrbStack,
colima), so that path stays. An endpoint that is not a local socket (`tcp://`, `ssh://`) is refused,
saying farmy needs a local Docker. The fake answers `docker context inspect` from `FAKE_DOCKER_CONTEXT_HOST`
(default `unix:///var/run/docker.sock`).

**D5. Ports bind 127.0.0.1 unless `LAN_HOST` is set.** A definition's `ports:` pair `3100:3000` is
published as `127.0.0.1:3100:3000`; with `LAN_HOST` in `.env`, on every interface. `farmy status` prints a
line `ports  127.0.0.1 only (LAN_HOST in .env opens them to the network)` or `ports  every interface
(LAN_HOST=<name>)` after the egress line; the JSON gets a top-level `"bind": "127.0.0.1" | "0.0.0.0"`. The
fragment's own `ports:` are passed as written.

**D6. `shared_logins: false` per service.** Such a service's app container does not mount `farmy-shared`,
and its agents' logins live on its own `<name>-agents` volume under `logins/`, seen by no other container.
The entrypoint learns where from `FARMY_LOGIN_DIR`: `/home/dev/.farmy-shared` by default,
`/home/dev/.farmy-service/logins` with `shared_logins: false`. The factory will use it.

**D7. No default agent.** Without `agents:` in `farmy.yml` no agent is on: images carry none, `farmy agents`
lists every catalogue entry `off`. `farmy init` asks on a terminal which agents to install (names from the
catalogue, space-separated; empty is none) and writes `agents:` into `farmy.yml` (creating it, or adding
the key; a `farmy.yml` that has `agents:` is not asked about); without a terminal it turns none on, writes
nothing, and says how to turn one on (`agents:` in `farmy.yml`). `farmy add` says which agents the image
will carry: `agents: claude (subscription), codex (api-key)` or `agents: none (agents: in farmy.yml turns
one on)`.

**D8. A git route without its secret forwards without credentials.** The broker's route spec gains a
fifth word, `public`, which farmy writes for every route with `git: true`: while such a route's secret is
not loaded, the broker forwards the request without adding credentials (the client's own `Authorization`
is still dropped), so public repositories on that host clone. A route without `public` answers 503 while
its secret is missing, as before. "Only public repositories clone" is true again, and the warning at
start says so, naming the secret to give. A private repository behind such a route fails to clone with
git's authentication words, and start names the route, its state and `farmy keys reload`. This
supersedes the 503 wording of 08:00 (D3 there). The fake: a token route's clone without the route's
secret succeeds, unless the test said the repository is private (`private_repository`); then git's
`could not read Username … terminal prompts disabled`.

## Tests altered

- `unlock_test.rb`: "an entry in the old Keychain form … is still found" and "an entry in the old secret
  service form … is still found" become "… is no longer found: one name only" (D2).
- `keys_test.rb` "a provider that fails … and start goes on to the containers", "a provider that answers
  with the protocol's error form …", `providers_test.rb` "providers/infisical with an identity Infisical
  rejects …": back to exit 0, since the public repository now clones through the unloaded git route (D8).
- `stranger_test.rb`: "with no value given start ends at the clone … never says public repositories"
  becomes two: start goes on and warns that only public repositories clone; a private repository ends at
  the clone naming the route's state (D8).
- Tests that leaned on Claude being on by default now turn it on in `farmy.yml` (D7): in `agents_test.rb`,
  `claude_test.rb`, `toolbox_test.rb`, `status_json_test.rb`, `mounts_test.rb`, `integration_test.rb`,
  where they touch an agent. A definition's `agents: {claude: api-key}` still turns that catalogue agent on for its service, so the tests that say so need nothing more.

## FORMATS.md

The holder, `farmy lock`, `unlock-names --missing`; the one lookup form; `egress.proxy`; the socket from
the context; the bind address, the status line and `bind`; `shared_logins`, `FARMY_LOGIN_DIR`; agents
default none, `init`'s question, `add`'s line; the `public` word of the broker's spec; the fakes
(`docker context inspect`, the held names behind `unlock-names --missing`, `private_repository`, and Go
templates with `range` and `if eq`: without them the shim's `{{range .Mounts}}` check came back empty and
every shim call made the control container anew, which a real Docker does not, and which would clear the
holder).

## Scenario list

hold_test.rb (new)
- after a start with an unlocking value, keys reload without one gives the provider the value the control container holds
- farmy unlock-names --missing lists only the names the holder does not have
- farmy lock clears the holder: the next reload without a value reads locked
- the held value is in no file, no docker command line and no output
- the shim asks the store only for the names the control container does not hold, and again after farmy lock

unlock_test.rb
- an entry in the old Keychain form, service farmy and account NAME, is no longer found: one name only
- an entry in the old secret service form, service farmy and account NAME, is no longer found: one name only

egress_test.rb
- with egress proxy every container and the provider get the proxy variables pointing at it, and no egress node runs
- with egress proxy no container gets ALL_PROXY, so SSH goes through the HTTP proxy
- egress proxy together with tailscale or an authkey is refused, naming both
- status shows an egress proxy on its line and in the JSON

shim_test.rb
- on a Linux host the control container gets the socket docker context names, a rootless one included
- a Docker context that is not a local socket is refused, saying farmy needs a local Docker

ports_test.rb
- a published port listens on 127.0.0.1 when LAN_HOST is not set
- with LAN_HOST the published ports listen on every interface
- status says the ports are 127.0.0.1 only without LAN_HOST, and every interface with it

mounts_test.rb
- a service with shared_logins: false mounts no farmy-shared and keeps its agents' logins on its own volume
- every other service links its agents' logins into farmy-shared

agents_test.rb
- without agents: in farmy.yml no agent is on: the image carries none and farmy agents lists every one off

init_test.rb
- init without a terminal turns no agent on, writes no farmy.yml, and says how to turn one on

add_test.rb
- add says the image will carry no agent without agents: in farmy.yml
- add names the agents the image will carry, with their modes

broker_test.rb
- a public git route forwards a request without credentials while its secret is not loaded
- a public git route adds its secret once it is loaded

keys_test.rb
- a git route's broker spec ends in public, an API route's does not

stranger_test.rb
- with no value given start goes on and warns that only public repositories clone from github.com until GITHUB_TOKEN is given
- a private repository with no value given ends at the clone, naming the route's state and farmy keys reload

help_test.rb
- the usage lists lock

integration_test.rb
- with shared_logins: false ~/.claude is on the service's own volume, not farmy-shared
