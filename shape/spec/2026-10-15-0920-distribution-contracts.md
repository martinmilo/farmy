# Distribution contracts

The owner confirmed configurable Docker-consumed source URLs, exact folder pins,
latest stable releases for unpinned updates, and app policy precedence
`true > audit > false`. For future formats, published labels identify a supporting
release; when unavailable, the required version is honestly unknown and the user
is directed to update. No additional version field is required in user files.

The shared contracts below are recorded in FORMATS.md for the worker. The scenario
list in the initial record remains the acceptance plan, with refusal boundaries,
repeat operations and failure preservation covered under those scenarios.

## Release and installation

`VERSION` in the program distribution is the one version source, initially 0.1.0.
Release versions and pins are exact stable `MAJOR.MINOR.PATCH` values, without a
leading v, suffixes or ranges. The release argument must match VERSION: changing a
version is a repository edit, never a silent side effect of publishing.

The registry is selected by FARMY_REGISTRY, with no built-in registry. An installed
shim remembers the registry chosen at installation; an environment override wins.
Each stable release publishes versioned and latest tags for farmy-control,
farmy-keys, farmy-knowledge and farmy-gate. Latest is the publisher's stable channel,
not a guess from registry tag ordering. All four images and farmy-built toolboxes
have version and build-hash labels. Vendor base images and user-owned sidecar images
remain vendor artifacts; their derived farmy images carry farmy's labels.

The control image contains the standalone POSIX shim at
`/usr/local/lib/farmy/farmy`. Docker create/cp/remove can retrieve it without running
a foreign architecture binary. The installer is `bin/install [--to VERSION]
[--dir DIR]`, defaults to `$HOME/.local/bin`, and installs exactly DIR/farmy. With no
version it resolves the control latest tag's version label. It does not overwrite
an existing shim until pulls and extraction succeed. It retains chosen registry
and optional FARMY_SOURCE defaults in the standalone artifact, not a host clone.

The shim uses its own versioned control tag by default. FARMY_BUILD=1 skips the
control pull. Failed pulls report the failure then try a local build; a checkout
can supply the build context, and a standalone shim uses FARMY_SOURCE, a remote
context URL understood by Docker. Missing fallback source is an actionable failure,
not a fake success. POSIX utilities and Docker suffice; host Git, curl, jq, Python,
Ruby and Rust are not runtime dependencies.

`farmy update` resolves latest unless the folder has an exact pin. `--to` explicitly
chooses a version, even while resolving a current mismatch; it does not rewrite the
folder pin. Updates pull all four exact release tags before replacing the installed
shim atomically. Failure preserves the old shim and existing running containers.
The shim warns about an already-running control image newer than itself, naming
both versions and `farmy update`, before selecting or recreating its normal control.

No actual registry publication is part of this task. Release runs in tests use a
fake buildx. The optional real integration exports one multi-platform image to a
temporary OCI archive, without publishing it. Docker's documented buildx platform,
label and push flags are the release interface:
[buildx build](https://docs.docker.com/reference/cli/docker/buildx/build/) and
[multi-platform builds](https://docs.docker.com/build/building/multi-platform/).
Registry examples follow the official
[GitHub Container registry guide](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
and [Forgejo registry guide](https://forgejo.org/docs/latest/user/packages/container/).

## Formats and drift

Both file kinds default format to 1. Format must be a positive integer. Current
farmy accepts 1; a greater value fails before changing containers. A control image
publishes `farmy.format`, its highest supported format (1 initially), as well as
`farmy.version`. Latest metadata may identify a newer capable reader. If it cannot,
the refusal names the file and requested format, says the required version is
unknown and gives `farmy update`. Lookup never runs the unsupported file through
the newer binary as a side effect. A folder version mismatch is checked before
ordinary work; update and --version remain available to fix or diagnose it.

Status compares the toolbox image's label with the current binary's version.
An older version produces `built by <old>, now <current>: farmy rebuild <service>`.
The JSON service object adds `toolbox_version` (string or null) and
`toolbox_outdated` (boolean), which the TUI can render without guessing.

## Audit and log output

Definitions accept both the established top-level restrict key and the requested
`egress.restrict`; the strongest setting among global and service inputs wins.
True means strict allowlist enforcement, audit means all destinations through the
gate, and false means existing unrestricted behavior. Factory profiles always use
strict selected-agent API hosts regardless of these app settings.

Each policy client optionally has `mode: audit`; absent mode means strict. Audit
still requires a recognized peer and still uses the configured upstream. It logs
the first normalized host/port pair per container per gate-process lifetime, even
for already-allowlisted destinations. Reload preserves that set. A different port
or container is a new destination observation. Unknown clients remain denied.

Events gain an RFC3339 UTC timestamp. Denials keep `event: denied`; audit observations
use `event: allowed` and `mode: audit`. No path, query, header or body is logged.
The latest 100 events include both types, while denied counts still count denials
only. Existing logs without timestamps render `-` for time. CLI default output is
one whitespace-separated line per event: time, service, container, host:port,
decision (`denied` or `allowed`). IPv6 destinations use brackets. `--json` returns
NDJSON, including filtered and retained factory events, with the existing keys.
Empty readable output says no egress events; empty JSON output has no lines.
The service status egress object retains `restricted` and `denied` and adds `mode`
with strict, audit or unrestricted; restricted is true for both gate-using modes.

The existing egress-control, factory-egress and integration log assertions switch
to --json for structured observations. Their behavioral meaning is preserved.
The old shim local-build caching cases explicitly set FARMY_BUILD=1, rather than
requiring all installations to compile. These are the only existing test meanings
changed by this record, apart from adding version metadata to status objects.
