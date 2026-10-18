# Worked example: a Mac, the Keychain, Infisical and a Headscale mesh

[Getting started](getting-started.md) walks the plainest path: Linux, a GitHub token, a prompt, no
mesh. This is the other end, a setup that swaps every part, as it ran on a real machine (names
rewritten to `example.com`):

- a Mac with OrbStack (Docker Desktop is the same), the unlocking values in the **Keychain**;
- the secrets in a self-hosted **Infisical** at `https://secrets.example.com`, opened with a machine
  identity (universal auth: a client id and a client secret);
- Infisical and the git host reachable only on a private mesh run by a **Headscale** control server
  at `https://mesh.example.com`;
- the git host, `git.example.com`, a Forgejo that answers SSH on port **2222**, the deploy key
  stored in Infisical base64-encoded.

Each step says what to look at, and what to paste when it breaks. Steps 1 to 3 are verified on a
real machine.

## 0. Before you start

- Docker running. `docker info` answers.
- A containers folder of your own, outside the farmy checkout: `mkdir ~/containers && cd ~/containers`.
- The shim on your PATH: `ln -s ~/farmy/work/farmy ~/bin/farmy`.
- The integration tests run from the checkout with Docker and Ruby there:
  `JOBS=1 bin/verify -n /Integration/`.

## 1. init (verified)

```sh
farmy init
```

Answer `claude` when it asks for the agents (step 5 uses it).

This builds the control image (a Rust build inside Docker, several minutes the first time; again
whenever the checkout's build inputs changed), starts the control container on the `farmy` network,
writes `.env` with your Git identity, and lists no services yet. Settings the shim reads may go into
`.env` too: `FARMY_SECRET_PREFIX`, `FARMY_UNLOCK_COMMAND`.

If it breaks: paste the output of `docker build -t farmy:local ~/farmy/work` and `docker logs farmy`.

## 2. One service with a public repository (verified)

```sh
farmy add https://github.com/<any public repository>.git --image debian:bookworm-slim
cat >> services/<name>.yml <<'Y'
ports: ["3100:3000"]
commands:
  setup: ls
Y
farmy start <name>
farmy status
farmy run <name> git log -1
farmy ssh <name>
```

Expected: `start` walks through its phases (`== secrets`, `== images: <name>`, `== containers:
<name>`, `== clone: <name>`), the toolbox builds on the image with its output collapsed to one line,
the clone shows in `farmy run <name> git log -1` (no pager), the shell is the `dev` user in
`/workspace`, and `farmy run <name> claude --version` answers.

If it breaks: `docker logs <name>`, and the build output `farmy start` printed.

## 3. The secrets manager, the mesh and SSH on port 2222 (verified)

`farmy.yml`:

```yaml
secrets:
  provider: [providers/infisical, --client-id-from, INFISICAL_CLIENT_ID, --client-secret-from, INFISICAL_CLIENT_SECRET,
             --domain, https://secrets.example.com, --projectId, <project id>, --env, dev]
  unlock: [INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET, TS_AUTHKEY]
egress:
  authkey: TS_AUTHKEY
  tailscale:
    login_server: https://mesh.example.com
keys:
  forgejo:
    secret: GIT_SSH_KEY
    upstream: ssh://git@git.example.com:2222
    auth: ssh
    git: true
    encoding: base64
```

With a provider, the shim obtains only the three names under `unlock:` on the Mac; the provider
fetches `GIT_SSH_KEY` from Infisical. Put the three into the Keychain once (`-T` lets `security`
read them back without a dialog):

```sh
security add-generic-password -a "$USER" -s farmy/INFISICAL_CLIENT_ID -w -T /usr/bin/security
security add-generic-password -a "$USER" -s farmy/INFISICAL_CLIENT_SECRET -w -T /usr/bin/security
security add-generic-password -a "$USER" -s farmy/TS_AUTHKEY -w -T /usr/bin/security
```

Reached over ssh, the login keychain is locked: the shim runs `security unlock-keychain` once and
reads on. The control container then holds the three values until `farmy lock` or its restart, so the
Keychain is asked once, not at every start.

The pre-auth key comes from Headscale, created under the user that owns the node's tag:

```sh
headscale preauthkeys create --user ops --tags tag:farmy --expiration 1h
```

Two Headscale lessons from the run: a node registered through the URL under a new user got no peers
until it was moved to the user that owns the tag the ACLs grant, and Headscale had to be restarted to
recompute the peer list; a pre-auth key made as above avoids both. And `tailscale ping` is not an ACL
test: it answers below the ACLs. Test the port through the proxy instead (mesh-egress.md, "On the
control server").

The key in Infisical is the private key base64-encoded (`base64 < deploy_key | tr -d '\n'`), hence
`encoding: base64`; without it, `farmy keys` says `rejected (it looks base64-encoded …)`. The port
in the upstream (`:2222`) goes into the clone URL and into git's `insteadOf` rule, so a repository
pasted as `https://git.example.com/acme/shop.git` is cloned from
`ssh://git@git.example.com:2222/acme/shop.git` and pushed the same way.

Then, with the private repository's `https://` URL in `services/<name>.yml`:

```sh
farmy restart <name>
farmy status
farmy keys
farmy run <name> git log -1
farmy run <name> git push
```

Expected: `start` prints `== egress` and the node joins (`farmy status`: `egress  registered
<node name> <mesh address>  kernel mode`); `farmy keys` shows the route `loaded`; the clone runs over
`ssh://git@git.example.com:2222/…` through the egress proxy with the key in the broker's agent
(`farmy run <name> ssh-add -l` lists it; `docker inspect <name>` shows no key); fetch and push work.

If it breaks: `farmy keys --why` (the provider's own error, redacted), `docker logs <name>-keys`
(what the agent took), `docker logs farmy-egress` (names it could not resolve), `docker logs <name>`
(the clone, retried when the cause may pass).

## 4. The session

```sh
farmy
```

Expected: the TUI with `<name>` running; `s`, `x`, `c` stream into the pane, `l` and `e` take the
screen over and come back; `q` leaves and the session stays; `farmy` again reattaches; from another
machine, `ssh -t host farmy` reattaches to the same session, and `ssh host farmy` (no terminal)
prints the usage instead.

If it breaks: `docker exec farmy tmux list-sessions`, and what the terminal showed.

## 5. Claude with a subscription

The login lives on the shared volume: log in once inside any container (`farmy ssh <name>`, then
`claude`) and every container has it. Or a long-lived token: `claude setup-token` on the Mac, stored
in Infisical as `CLAUDE_CODE_OAUTH_TOKEN`; the provider yields it and farmy puts it into the app
container (the one documented exception to "no secret in a container"). Then:

```sh
farmy restart <name>
farmy run <name> claude -p "say hello"
```

Expected: Claude answers without asking to log in; `farmy run <name> claude mcp list` shows `farmy`.

## What is not verified yet

The toolbox on apk (best effort), a mount's ownership, the TUI in every terminal, Claude with a token
from the provider (step 5).
