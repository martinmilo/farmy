# Egress filtering and mesh access

The public modes are `off`, `audit` and `enforce`: off permits a direct route, audit records proxy
destinations, and enforce allows only configured destinations.

Set `egress.restrict: enforce` in `farmy.yml` to restrict every app's outbound traffic. A definition
can opt in with `restrict: enforce` or `egress: {restrict: enforce}`. The strongest setting
wins: `enforce`, then `audit`, then `off`. An omitted setting is off. The legacy booleans
`true` and `false` remain aliases for enforce and off. A service cannot weaken a workspace restriction.
Factory agents always use enforced filtering in either authentication mode, regardless of app settings.

```yaml
egress:
  restrict: enforce
  allow: [docs.example.com, 'downloads.example.com:8443']
  services:
    shop:
      allow: [private-packages.example.com]
```

An egress map containing only `restrict`, `allow` and `services` creates no mesh node. An empty
`egress: {}` keeps the earlier meaning: start a mesh node. The `authkey`, `tailscale` or
`join_timeout` fields also request a mesh; `proxy` selects an existing HTTP proxy.

## Allowed destinations

Apps may reach the package registries in `egress-hosts.yml`, the `api_hosts` of their enabled
agents, the upstream hosts of configured git routes, and your additions. Additions combine
`egress.allow`, `egress.services.<name>.allow` and the definition's `egress: {allow: [...]}`.
`@registries` expands the shipped set. Unknown set names are rejected.

An entry is a DNS name or IP, optionally with a port, such as `docs.example.com:443` or
`[2001:db8::1]:443`. Without a port it allows any port. `*.example.com` matches complete
subdomains, including `a.b.example.com`, but excludes the apex and `badexample.com`. Names are
case insensitive and ignore one final dot. URLs, paths, user information and other wildcard
forms are rejected. Explicit git-route ports stay restricted to that port.

Factory agents get only their selected agent's `api_hosts`. App additions never widen that
policy. API-key mode also keeps its fixed credential-broker route. Override `api_hosts` in the
agent catalogue when using another model provider; the list replaces the shipped list rather
than appending to it. Shipped defaults and their sources are documented in `agents.yml`.

For interactive apps whose agents use WebFetch, `restrict: audit` is useful for learning the
destinations they need. Audit keeps the app on its internal network and sends requests through
the same gate and configured upstream, but permits all destinations for recognized clients.
It records each normalized host/port pair once per container for the gate process lifetime,
including allowlisted hosts. A new port is a separate observation; reloading policy keeps the
observations. Unknown clients are still denied. Use enforced filtering for unattended factory
runs; app audit settings never broaden a factory's selected-agent policy.

## Enforcement and live changes

Restricted apps and factory agents start only on internal Docker networks. Their HTTP proxy
variables point at a filtering gate, and ignoring the proxy gives no direct route out. The
gate checks the requested hostname and port before connecting; denied requests return 403.
HTTP requests are checked by their destination host and port. HTTPS uses opaque CONNECT
tunnels, with TLS bytes passed through unchanged; encrypted paths and payloads are not inspected.
SSH git also uses CONNECT. Both audit and enforce keep other protocols without an independent
outward route: applications that ignore the proxy cannot bypass the internal network.
Image builds are outside the runtime gate and may download build dependencies directly.
Local brokers and sidecars remain directly reachable. The filtering control socket is never
mounted in a restricted client.

The gate connects directly or uses the configured mesh/external HTTP proxy as its upstream.
`FARMY_EGRESS_PROXY` overrides that upstream. It does not replace the restricted client's gate.
Upstream failure returns 502 and never retries directly. Control, credential brokers and
sidecars retain their own network behavior; an app's restriction applies to the app container.

```sh
farmy egress allow docs.example.com
farmy egress allow packages.example.com:443 --service shop
farmy egress log
farmy egress log shop
farmy egress log shop --json
```

`allow` normalizes and saves the entry once, then reloads affected running app gates. Containers
keep running, restriction settings stay as configured, and factory policies stay unchanged.
The next request sees the change; an established CONNECT tunnel can finish. An invalid host or
unknown service leaves configuration untouched.

`log` shows the latest 100 events, oldest first, as whitespace-separated fields: UTC timestamp,
service, container, host:port and decision (`allowed` or `denied`). IPv6 destinations have
brackets. Older retained records without a timestamp show `-`; an empty log says `no egress
events`. `--json` emits NDJSON with the machine-readable event fields and emits nothing when
empty. Events contain no URL paths, queries, headers, credentials, bodies or TLS contents.
Each service in `status --json` has an `egress` object with `restricted`, `mode` and `denied`;
mode is `enforce`, `audit` or `off`, and both enforce and audit are restricted. The
session shows the mode and denial count beside each service. Allowed audit observations do
not increase the denial count.
Counts survive policy reload but reset when an app gate process restarts. Factory cleanup saves
its gate's count and recent records under `.work/<service>/runs/<id>/egress.json`, so completed,
cancelled and interrupted runs remain visible while their run records exist.

## Mesh access

Your secrets provider, your git host or an API may live on a private mesh: a tailnet on Tailscale's
own control server, or on a control server of your own (Headscale, for example). With `egress:` in
`farmy.yml`, farmy keeps one node on that mesh and reaches mesh hosts through it. The node is a
proxy, not an exit node. Unrestricted containers keep their direct internet. Restricted clients
reach the mesh only through their filtering gate and its allow list.

```yaml
# farmy.yml
secrets:
  unlock: [TS_AUTHKEY]                # obtained on this machine like any value (a prompt, the secret service, …)
egress:
  authkey: TS_AUTHKEY                 # a tagged auth key; absent: register by URL
  join_timeout: 10m                   # how long start waits for the node to register
  # tailscale:
  #   login_server: https://headscale.example.com   # a control server of your own; omitted: Tailscale's
```

With Tailscale's own control server, make an auth key in the admin console with the tag your ACLs
grant (`tag:farmy`, say) and store it under the name `authkey` gives. A control server of your own
takes `tailscale.login_server`; everything else is the same.

## An existing proxy

Behind a corporate HTTP proxy, with no mesh at all:

```yaml
# farmy.yml
egress:
  proxy: proxy.example.com:3128
```

No mesh node runs. Unrestricted containers and the provider get `HTTP_PROXY` and `HTTPS_PROXY` (both
cases) as `http://proxy.example.com:3128` and the `NO_PROXY` below; no `ALL_PROXY`, since such a proxy
speaks HTTP only. Restricted clients use their gate, which forwards permitted requests to this
upstream. git over SSH goes through it by HTTP CONNECT (`ProxyCommand nc -X connect -x
proxy.example.com:3128 %h %p`), as does farmy's own fetch of a Dockerfile. `farmy status` prints
`egress  proxy  proxy.example.com:3128`. `proxy` does not go with `authkey` or `tailscale`: farmy refuses
the pair. The rest of this guide is about the mesh.

## What runs

One container, `farmy-egress`, on the `farmy` network, never published, running `tailscaled` in
kernel mode: the container gets the device `/dev/net/tun` and the capability `NET_ADMIN`, and the
login passes `--accept-dns=true`, so tailscaled manages the container's resolver and the proxies
resolve every name the tailnet's DNS knows, extra records and split DNS included. Docker Engine on
Linux gives both. Where the Docker daemon will not give the node the device or the capability (rootless
Docker, some hosted runners), farmy runs it in userspace mode instead and says so at start and in
`farmy status`: then only names under the tailnet's suffix (`<host>.<tailnet>.ts.net`, or your
control server's base domain) resolve through the proxy. It serves a SOCKS5 and an HTTP CONNECT proxy
on port 1055 to the farmy network only. Its state lives on the volume `farmy-egress`, so registration
happens once per machine, not per start.

Unrestricted containers (the keys broker, knowledge container, unrestricted apps and the
sidecars of your `compose:` fragment) and the provider process get these proxy variables, in
both cases. Restricted clients instead get HTTP proxy URLs pointing to their filtering gate:

```
HTTP_PROXY=http://farmy-egress:1055     HTTPS_PROXY=http://farmy-egress:1055
ALL_PROXY=socks5h://farmy-egress:1055   NO_PROXY=localhost,127.0.0.1,host.docker.internal,<the project's names>,farmy,farmy-egress,farmy-knowledge
```

`HTTP_PROXY` and `HTTPS_PROXY` are the HTTP CONNECT proxy, which Go programs (the Infisical CLI), apt,
pip, npm and Ruby understand, and which resolves names on the proxy side; `ALL_PROXY` is SOCKS5 for
curl and the SSH `ProxyCommand`. `FARMY_EGRESS_PROXY=<host:port>` in farmy's environment replaces
`farmy-egress:1055` as the upstream, for a proxy of your own.

Every unrestricted container using the mesh is on the `farmy` network, where `farmy-egress` resolves by name:
the control container (the shim starts it there and attaches one from an older farmy), the app
container when unrestricted, and with mesh configuration the fragment's services. A restricted
app stays internal; its gate joins `farmy` to reach the mesh proxy.

So the provider, curl, package managers and the broker's upstreams reach mesh hosts, and MagicDNS
names resolve on the mesh (`socks5h`: the proxy resolves them). Git over SSH in the app containers
goes through the SOCKS proxy too: the toolbox installs `netcat-openbsd` and the entrypoint sets
`core.sshCommand` with `ProxyCommand nc -X 5 -x farmy-egress:1055 %h %p`.

## Joining

`authkey` names an unlocking value, listed under `secrets.unlock` and obtained by the shim like the
others (a prompt, the secret service, a command or the Keychain), not a provider secret: the provider
itself may sit behind the mesh, so the node is up before any provider runs. The order at start is
unlocking values, then the egress node, then the provider, then the brokers. The key reaches the
node on the stdin of a `docker exec`: it is in no file, no command line and no `docker inspect`.

With the key, the node joins by itself. Without, farmy starts the container, reads the
registration URL from its log, prints it once with the instruction to register the node on the
control server, and waits up to `join_timeout`. On timeout start goes on: services that need no
mesh still work; `farmy status` shows the node as unregistered with the URL, and a service whose
clone then fails says so. Once registered, the next start says nothing.

## Seeing it

`farmy status` prints an `egress` line first: `registered`, the mesh name and address, or
`unregistered` with the URL, or `stopped`, then the mode (`kernel mode` or `userspace mode`).
`farmy status --json` has the same under `egress`, and the session shows it in its title.
`farmy stop` with no name stops the node too; `farmy destroy` never touches its volume.

## On the control server

- **Register with a tagged key.** A node registered through the URL belongs to whoever registered
  it and carries no tag until someone gives it one, so ACLs written for a tag do not apply to it yet.
  An auth key made with the tag (in Tailscale's admin console; `headscale preauthkeys create --user
  <the tag's owner> --tags tag:farmy` on Headscale) registers the node with the right owner and tag
  at once. Store it under the name `egress.authkey` gives, and the node joins by itself.
- **`tailscale ping` is not an ACL test.** It answers below the ACLs, so a successful ping says the
  nodes see each other, not that a port is open. Test a port through the proxy instead, from any
  farmy container: `curl -sS --proxy socks5h://farmy-egress:1055 https://git.example.com`.
- **Names.** `tailscale dns query <name>` on the node (`docker exec farmy-egress tailscale dns query
  git.example.com`) shows what the tailnet's DNS answers; in kernel mode the proxies resolve the same.
- **SSH route upstreams carry the port.** When the git host answers SSH on another port than 22 (often
  the case behind an ACL that opens only that port), write it in the route's upstream,
  `upstream: ssh://git@git.example.com:2222`: the clone URL and git's `insteadOf` rule for later
  fetches and pushes carry it; without it, the node dials port 22.

A control server of your own may have lessons of its own; Headscale's, from a real run, are in the
[worked example](worked-example.md).
