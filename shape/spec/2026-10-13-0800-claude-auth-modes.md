# 2026-10-13 08:00 — Claude in a container: subscription or API key, nothing shared

The review of the previous answers settled how Claude Code authenticates inside an app container.
Two facts drive it: `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` outrank a subscription login, so a
route exposing them silently turns a subscription into per-token billing; and a shared `~/.claude`
lets every agent read every other repository's session transcripts.

## What was decided

- **A per-service mode: `subscription` (default) or `api-key`, or `off`.** `farmy.yml` sets the
  default under `claude.mode`; a definition's `claude:` overrides it for that service.
- **Subscription mode** uses a token made with `claude setup-token` (a year-long token meant for
  scripts, model requests only, no Remote Control, no connectors): its secret name is
  `claude.token` in `farmy.yml`, obtained from the provider like any secret, and given to the app
  container as `CLAUDE_CODE_OAUTH_TOKEN` in its environment. This is **the one documented
  exception** to the rule that no secret is in a container's configuration: the agent can read it,
  and nothing fixes that; what limits the damage is egress control, which is a later piece. In
  this mode the container gets none of Claude's variables from a route: no `ANTHROPIC_BASE_URL`,
  no `ANTHROPIC_API_KEY`, no `ANTHROPIC_AUTH_TOKEN`, whatever the routes expose.
- **API-key mode** goes through the broker: the route exposes `ANTHROPIC_BASE_URL`, and a route may
  now name a **`placeholder`** variable the app gets with the fixed value `via-farmy-keys`
  (`ANTHROPIC_API_KEY`), so that Claude Code uses key auth and the broker swaps the real key in.
  No token in the container.
- **Nothing of Claude is shared between services.** Each service gets a volume of its own,
  `<name>-claude`, at `/home/dev/.claude` (`CLAUDE_CONFIG_DIR`); the shared `dev-identity` volume
  goes. `dev-tooling` (editor extensions) stays, with the libc caveat noted in the docs.
- `off` for a service: no token, no `CLAUDE_CONFIG_DIR`, no volume; `agents: []` in `farmy.yml`
  means off for every service and no Claude in the toolbox.

## Left out

- Egress control (an internal network and an allowlist), the real safeguard for a readable token.
- Codex and other agents: the same shape later.

## Test altered

`keys_test.rb`, "the app container gets the variable a route exposes, pointing at the route": the service is
now in api-key mode, since in subscription mode (the default) Claude's variables are kept out.

## Scenario list

claude_test.rb
- in subscription mode the app container gets the Claude token and none of Claude's route variables
- in api-key mode the app container gets the base URL and the placeholder, and no token
- each service keeps Claude's data on a volume of its own
- a service with claude off gets neither the token nor Claude's settings
