# Egress control

The proxy variables currently invite a container to use a proxy while leaving it a
direct route out. Restriction must come from Docker topology. This record starts the
shaper-and-worker cycle on `farmy-workbench`: record and scenarios, acceptance tests,
then a separate worker implementation commit. The user supplied the scenarios and
requested the whole cycle.

## Decision

Every restricted container sits only on internal Docker networks. Its single way out
is a filtering HTTP proxy, `farmy-gate`, with an outward network. The gate supports
plain HTTP and CONNECT, permits destinations by host and optional port, records every
denial with host, port and container, and tunnels TLS without inspecting it. With mesh
egress or a configured upstream proxy, the gate forwards through that proxy. Without
either, it connects directly. The worker may choose a new Rust crate or a broker mode.

Agent catalogue entries gain verified, cited `api_hosts` data. Git routes contribute
their hosts. A shipped named registry set includes Debian and Alpine mirrors,
rubygems.org, registry.npmjs.org, pypi.org, files.pythonhosted.org, proxy.golang.org,
crates.io and static.crates.io. Configuration supplies additional global and service
hosts; there are no project-specific hostnames in the implementation.

Factory agents are always restricted to their selected agent's `api_hosts`. This
replaces their per-run outward network. The factory test gate remains isolated with
only its sidecars. Apps opt in through `farmy.yml` `egress.restrict: true` or a service
definition's `restrict: true`; their policy includes agent hosts, git routes, registry
hosts and configured extras. Control, credential broker and mesh egress behavior stays
as it is for unrestricted workloads.

`farmy egress log [service]` shows recent denials. The TUI exposes denial counts by
service. `farmy egress allow <host> [--service s]` persists an addition in `farmy.yml`
and reloads running gates without restarting containers.

The default prompt for a `red_first` profile explicitly requires a test to fail when
any of its checks fails: shell suites need `set -e` or equivalent, and assertions must
not be swallowed. The first real shaper produced two greps whose exit status reflected
only the second check; that is the concrete regression behind this requirement.

## Open questions

- What exact matching syntax is needed for vendor subdomains, and does a host without
  a port permit all ports? Vendor documentation will establish necessary patterns.
- How should global restriction interact with a service's explicit `restrict: false`?
  The conservative reading of the requested OR is that global restriction wins.
- Which config shape stores CLI additions for one service while preserving a global
  `egress.allow` list? Definition extras and workspace additions need an unambiguous
  union, and configuration containing only restriction settings must not require mesh.
- Which documented endpoints are essential for subscription authentication and API
  access for each of the six shipped agents? Provider-selecting agents need a stated
  default, and custom entries must be able to replace that default.
- What policy and log interchange permits a deterministic fake and a real proxy test
  without depending on a crate layout? Attribution must come from trusted container
  identity, not an HTTP header supplied by the caller.
- What is the lifetime of the visible denial count and how much history is shown?

These questions will be settled explicitly in a follow-up contract before tests are
handed to the worker. No unrestricted network fallback is an acceptable answer to a
missing destination.

## Changed meaning and exclusions

The factory token/API network tests in `factory_test.rb` change meaning: an agent no
longer obtains a direct route out. Existing unrestricted mesh/proxy app behavior stays
covered. This supersedes the corresponding topology in the factory-agent-network
record and the advisory-only scope of the mesh-egress record. TLS interception, packet
inspection and arbitrary non-HTTP forwarding are outside this change.

## Scenarios

- A restricted app has only internal networks and reaches an allowed HTTP or HTTPS host through its gate.
- Ignoring proxy variables leaves that app without a direct route out.
- An unlisted destination is denied and the log identifies its host, port and container.
- Matching uses host boundaries and honors an explicitly allowed port.
- An app's policy combines enabled agent hosts, git route hosts, named registry hosts and global and service additions.
- Restriction can be enabled globally or for one service without requiring a mesh.
- Unrestricted apps retain existing behavior and do not acquire a filtering gate.
- Each shipped catalogue entry declares API destinations supported by cited vendor evidence.
- A custom catalogue entry supplies its own API destinations without a code change.
- A factory agent reaches its selected agent's API host but cannot reach registry, git or app-only additions.
- A factory test gate still has no way out, and run cleanup removes the filtering resources.
- A configured mesh or upstream proxy receives the filtering gate's allowed traffic.
- Log selection and status data expose each service's denial count for the TUI.
- A global allow addition takes effect on running gates without restarting any container.
- A service-only addition changes that service's policy without granting it to another service.
- A red-first default prompt says that failure of any check must fail the test.
- Real Docker integration curls an allowed host successfully and receives a denial for example.com.
- A real proxy accepts plain HTTP and opaque CONNECT, rejects an unlisted host, and reloads policy without a process restart.
