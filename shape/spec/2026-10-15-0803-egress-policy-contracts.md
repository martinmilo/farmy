# Egress policy contracts

This settles the open questions in the egress-control record before acceptance tests.
The user confirmed that global restriction wins over a service's `restrict: false`,
and confirmed global `egress.allow`, workspace `egress.services.NAME.allow`, and
definition `restrict` plus `egress.allow`.

Exact hosts are case-insensitive, with a final DNS dot ignored. A host alone permits
any port; `host:port` permits just that port. A leading `*.` permits proper subdomains
at any depth, never the apex or a name that merely ends with the same letters. This
is needed by Copilot's documented API routing. No other wildcard, scheme, path or
userinfo syntax is accepted. The shipped API destinations use port 443.

The named `registries` set uses the common Debian and Alpine CDN mirrors and the
package hosts requested in the first record, including RubyGems' download host and
the sparse crates index. Apps automatically include it; `@registries` is its explicit
spelling in an allow list. Factory agents never inherit app extras, other agents,
git routes or registries. A custom factory agent without `api_hosts` has an empty
allowlist, never unrestricted access. Users select alternate provider destinations
through catalogue overrides. The OpenCode default is its own hosted inference API;
it does not grant every provider OpenCode can use.

Restriction-only config does not start a mesh. Existing empty `egress: {}` and the
existing mesh fields retain their earlier meaning. A configured upstream receives
allowed traffic, with no direct fallback on its failure. App service networks are
internal when restricted, and the app never joins outward `farmy`. The credential
broker remains available locally with its existing fixed routes. Factory test gates
never join the filtering proxy's network. The worker may organize filtering gate
processes per client or share them with distinct policies, but cannot trust HTTP
headers for client identity.

The stable executable seam is `bin/farmy-gate serve|load|log|status`, analogous to the
credential broker. Loading uses a Unix socket and versioned JSON, inaccessible to
apps. Policy selects clients by their actual peer IP, mapped by trusted config to a
container and service; optional Docker DNS names avoid fixing IPs before a container
starts. Unknown peers fail closed. Denials are JSON lines containing host, port,
container and service, also written on stdout. `log` returns the latest 100 denials;
`status` counts denials since the process started. Farmy retains factory denials
before removing its run resources, and service status includes retained run denials
plus live gate counts. TUI counts use that service data. Reload preserves counts.

The API destination evidence was checked on 2026-10-15. Lists and exact executable
contracts are in FORMATS.md. These are the API/authentication subset needed for the
documented default providers, not a grant to installers, telemetry, browser assets,
MCP servers or web-fetch destinations:

- Claude: [enterprise network requirements](https://code.claude.com/docs/en/network-config)
  documents api.anthropic.com, claude.ai and platform.claude.com, including token refresh.
- Codex: [sample configuration](https://learn.chatgpt.com/docs/config-file/config-sample),
  [app server authentication](https://learn.chatgpt.com/docs/app-server), and
  [API access](https://developers.openai.com/api/docs/guides/ip-allowlist) establish
  chatgpt.com, auth.openai.com and api.openai.com respectively.
- Gemini: [API discovery](https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta),
  [Code Assist client](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts),
  [CLI OAuth client](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts),
  and [Google native OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
  establish generativelanguage.googleapis.com, cloudcode-pa.googleapis.com,
  www.googleapis.com, accounts.google.com and oauth2.googleapis.com.
- OpenCode: [hosted model endpoints](https://opencode.ai/v2/docs/console/models/)
  use opencode.ai. Another provider requires a user override.
- Cursor: [network configuration](https://cursor.com/docs/enterprise/network-configuration)
  identifies api2.cursor.sh, api5.cursor.sh and its agent subdomains, and the
  authenticate/authenticator/authentication token endpoints. Browser sign-in assets
  are outside the unattended container's default grant.
- Copilot: [allowlist reference](https://docs.github.com/en/copilot/reference/copilot-allowlist-reference)
  documents github.com, api.github.com, *.githubcopilot.com,
  copilot-proxy.githubusercontent.com and origin-tracker.githubusercontent.com for
  authentication, API access and public-code checks.

The initial scenario list stands. Additional boundary examples make its matching,
identity and reload scenarios concrete: an incorrect port and suffix lookalike are
denied; a caller cannot choose another client's policy with a header; a malformed
reload leaves the prior valid policy active; an upstream failure never bypasses it;
and adding a duplicate allowed host neither restarts a container nor duplicates YAML.
No policy questions remain open. Real Docker integration still requires a Docker
daemon; the proxy acceptance tests use loopback and run without one.
