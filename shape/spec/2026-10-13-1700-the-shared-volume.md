# 2026-10-13 17:00 — One shared volume: farmy-shared

Finding 6 of the first run. What a tool keeps per user, and what should exist once across every
container (logins, editor extensions), was split between the `dev-tooling` volume (extensions)
and the per-service `<name>-claude` volume (Claude's login *and* its transcripts). One rule
instead.

## The rule

- **Shared across containers → `farmy-shared`.** One volume, mounted in every app container at
  `/home/dev/.farmy-shared`, a folder per tool inside it: `claude/`, `codex/`, `vscode/`,
  `cursor/`, and whatever else a tool keeps per user. The entrypoint links each tool's own path
  into it (`~/.claude` → `.farmy-shared/claude`, `~/.codex` → `.farmy-shared/codex`, an editor
  server's `extensions` → `.farmy-shared/<editor>/linux-<arch>/extensions`), the way it linked
  extensions before. The `dev-tooling` volume is gone, merged into it; the `dev-` prefix goes.
- **Project state → per-service volumes.** Transcripts stay per service: `<name>-claude` is
  mounted at `/home/dev/.farmy-service/claude`, and `~/.claude/projects` is a link into it.
  Nothing of one service's sessions is readable from another.
- **Binaries → the image.**

Factory runs will not mount `farmy-shared`; that is the factory record's business.

## Decided

- Every app container mounts `farmy-shared` (an external volume farmy creates) at
  `/home/dev/.farmy-shared`, Claude on or off (editors need it either way). No container mounts
  `dev-tooling`, and farmy no longer creates that volume.
- `<name>-claude` is mounted at `/home/dev/.farmy-service/claude` when Claude is on for the
  service; `CLAUDE_CONFIG_DIR` stays `/home/dev/.claude`, which the entrypoint makes a link to
  `/home/dev/.farmy-shared/claude`, with `projects` inside it a link to
  `/home/dev/.farmy-service/claude/projects`. The entrypoint makes both volumes the dev user's.
- `destroy` removes `<name>-claude`; nothing removes `farmy-shared`.

## Scenario list

claude_test.rb (changed)
- each service keeps Claude's transcripts on a volume of its own, mounted under .farmy-service, and shares its login through farmy-shared

mounts_test.rb (new tests)
- every app container mounts farmy-shared at /home/dev/.farmy-shared and nothing named dev-tooling
- destroy keeps farmy-shared

integration_test.rb
- inside the container ~/.claude is on farmy-shared and ~/.claude/projects on the service's own volume
