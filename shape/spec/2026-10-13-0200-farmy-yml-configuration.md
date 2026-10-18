# 2026-10-13 02:00 — farmy.yml: what varies between projects becomes a setting

The owner, reviewing `work/` before the first push: "we need to consolidate the whole dev-creds and make it
somehow generic ... This applies to all of the stuff within the implementation, it needs to be
configurable, currently it's all hardcoded." Then, on the first proposal: "is this too complicated? ...
I fear that I'm making it too concrete, while on the other hand making it completely generic could
mean lot of work." The line agreed: **a setting exists only where two real projects would answer
differently.** Names, paths, the uid, shell aliases and the knowledge container's port stay fixed.

## What was decided

- **One optional file, `farmy.yml`, in the containers folder**, with four optional sections. farmy
  ships the defaults it uses when the file, or a key in it, is absent; `farmy.yml` overrides key by
  key. A key set empty removes a default. An unknown key is refused by name, so a typo cannot
  silently fall back to a default. `farmy config` prints every setting in effect. A change to
  `farmy.yml` after a service started shows in `status` like a changed manifest and applies at
  `restart`. Most containers folders will have no `farmy.yml` at all; the README shows one example
  of ten lines (a Mailpit sidecar, an Anthropic route).
- **`credentials`: the helper becomes one generic token proxy.** `credentials.routes.<name>` names
  an upstream URL, how the token is sent (`basic` with a user, `bearer`, or a `header`), the `.env`
  key holding the token (with `<KEY>_<OWNER>` per first path segment, as today for the forge), and
  optionally `expose`: the variable the app container gets that points at the route
  (`ANTHROPIC_BASE_URL=http://creds:9181/anthropic`). Every route is reached from the app container
  as `http://creds:9181/<route>/...`. The `forge` route ships, marked `git: true`: the app
  container's git goes through it, as today. A route whose token is not in `.env` is switched
  off with a warning naming the key; the git route without a token still works for public
  repositories. Tokens still reach only `<service>-creds`. `farmy.yml` holds key names, never
  tokens, so it can be committed.
- **`sidecars` are defined, not built in.** Each has an image, a port, the data path and the volume
  mounted there, the container's environment, a readiness command farmy waits for, and the
  variables the app gets unless its manifest's `env:` sets them. Postgres (short name `pg`, so its
  container and volume stay `<service>-pg`, `<service>-pg-data`) and Redis ship; a containers
  folder changes them or adds others, and a manifest's `services:` names any defined one. An
  undefined name is refused.
- **`app`: the environment pushed into every app container, the default port, and the setup
  commands.** The setup runs after the clone, in the checkout (or its `workdir:`), as the dev user,
  in order; farmy runs it from the host so that `farmy start` shows it and a failing command is
  reported and stops the rest. The entrypoint inside the container only clones. The defaults keep
  today's behaviour (`bundle install` when there is a Gemfile, `npm install` when there is a
  package.json).
- **`toolbox` and `agents`**: the apt packages and the pinned tools the toolbox installs, a
  `pins.tsv` next to `farmy.yml` that replaces farmy's, and `agents: [claude]` for Claude Code
  (installed, its login kept on the shared volume, the login step offered). `knowledge: false`
  switches the shared knowledge container off.
- **Contracts**, fixed in `FORMATS.md` so that the pieces can run or build on their own: the helper
  reads its routes from `FARMY_ROUTES` / `FARMY_ROUTE_<NAME>` in its environment; the toolbox image
  takes `PACKAGES` and `TOOLS` as build arguments and the pins file in its context.

## Left out

- Names, paths, the uid, aliases, the knowledge container's port: fixed, by the line above.
- Per-service overrides of `farmy.yml` keys inside a manifest.
- Validation beyond unknown keys: a wrong image or a bad command is Docker's to report.
- Watching `farmy.yml` for changes.

## Still open

- Whether the host's existing token proxy is retired once the helper proxies API calls.

## Scenario list

One sentence per test. New files under `test/farmy/`; existing tests keep their meaning.

config_test.rb
- a containers folder without farmy.yml gets farmy's defaults
- a key in farmy.yml replaces that default and the other defaults stay
- an unknown key in farmy.yml is refused by name
- a default set empty in farmy.yml is removed
- config prints every setting in effect, defaults and overrides alike
- a farmy.yml changed since a service started is reported by status like a changed manifest

sidecars_test.rb
- a sidecar defined in farmy.yml can be asked for in a manifest
- a manifest asking for a sidecar that farmy.yml does not define is refused by name
- a sidecar's image, environment and data path come from farmy.yml
- the variables a sidecar gives the app come from farmy.yml
- a manifest's own value wins over the variable a sidecar gives
- farmy waits for a sidecar with the readiness command farmy.yml names

app_test.rb
- the environment farmy.yml lists reaches every app container
- the default app port comes from farmy.yml
- without farmy.yml the setup installs the bundle and the npm packages when their files are there
- the setup commands farmy.yml lists run in the checkout after the clone, in order
- a service with a workdir runs its setup there

toolbox_test.rb
- the toolbox image is built with the packages farmy.yml lists
- the toolbox image is built with the tools farmy.yml lists
- a pins file next to farmy.yml is the one the toolbox is built from
- with Claude not among the agents the app container gets no Claude settings
- with the knowledge container switched off nothing shared starts

credentials_test.rb
- every route farmy.yml defines reaches the credentials helper with its token from .env
- a route's token never reaches the app container
- the app container gets the variable a route exposes, pointing at the route
- a route whose token is not in .env is switched off with a warning naming the key
- the forge is a route of the helper with basic auth and FORGE_TOKEN
