# 2026-10-15 01:00 — The mesh from every container

The owner ran record 2500 on the Mini. The egress node registered and status showed its mesh name
and address. Two failures followed, and two small asks.

## Decided

1. **Every container that uses the proxy is on the `farmy` network.** The shim created the control
   container on the default bridge, where container names do not resolve: the provider, run there,
   got "Could not resolve proxy: farmy-egress". The shim creates the `farmy` network when it is
   missing and starts the control container on it, and attaches a control container from an older
   farmy to it (`docker network connect`). The app container was already on `farmy`; with `egress:`
   the fragment's services join it too, since they get the proxy variables. Integration: the control
   container resolves `farmy-egress`.
2. **The toolbox installs an SSH client**: `openssh-client` on apt and apk bases. git's SSH clone
   failed with `ssh: not found`. Integration: `ssh` is in the app image.
3. **The proxy variables stay as they are**: `HTTP_PROXY` and `HTTPS_PROXY` are the HTTP CONNECT
   proxy, `http://farmy-egress:1055`, which Go programs (the Infisical CLI), apt, pip, npm and Ruby
   understand and which resolves names on the proxy side; `ALL_PROXY=socks5h://…` for curl and the
   SSH ProxyCommand. Tested now through a real CONNECT proxy: the Infisical provider's CLI reaches
   its domain through it. For that, and for a proxy of your own, **`FARMY_EGRESS_PROXY=<host:port>`**
   replaces `farmy-egress:1055` in every proxy variable.
4. **`farmy keys --why`** runs the provider once, as `keys reload` would (the unlocking values from
   the shim, the egress node first), and prints how it ended and its stderr, with every secret and
   unlocking value replaced by `[redacted]`. Nothing is loaded. **`FARMY_SECRET_PREFIX`** is read from
   `.env` in the containers folder as well; the environment wins. `.env` accepts the key.

## FORMATS.md

- The control container on `farmy`; the fragment's services on `farmy` with `egress:`.
- `openssh-client` in the toolbox.
- `FARMY_EGRESS_PROXY`.
- `farmy keys --why`, its output, the shim obtaining the unlocking values for it.
- `.env`: `FARMY_SECRET_PREFIX`.
- The fakes: `docker network connect`/`disconnect`; the fake `infisical` goes through
  `HTTPS_PROXY` by CONNECT to its `--domain` when both are set.

## Tests altered

None.

## Scenario list

shim_test.rb
- the control container is started on the farmy network, which the shim creates when it is missing
- a control container from before, on the default bridge, is attached to the farmy network

egress_test.rb
- with egress the fragment's services are on the farmy network too, so they resolve the egress node
- with FARMY_EGRESS_PROXY every proxy variable points at that address instead

providers_test.rb
- with egress the Infisical CLI reaches its domain through the HTTP CONNECT proxy

keys_test.rb
- keys --why runs the provider once and prints its stderr with every secret and unlocking value redacted
- keys --why loads nothing into a broker

unlock_test.rb
- FARMY_SECRET_PREFIX in .env is used when the environment has none
- the shim obtains the unlocking values for keys --why

toolbox_test.rb
- the toolbox installs an SSH client, openssh-client, for git over SSH

integration_test.rb
- the control container resolves the egress node by name
- the app image has an ssh client for git
