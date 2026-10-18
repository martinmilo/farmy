# 2026-10-14 23:02 — A deterministic proxy observation

The worker's baseline stopped on a Ruby DNS exception in the existing Dockerfile-fetch proxy test.
The same exception was in the shaper's baseline log. The fake proxy recorded the request, satisfying the
test's routing assertion, and then tried to resolve the example host on the real network. Its thread
exception caused the runner to report a harness error, even though the child printed a passing
assertion count. The aggregate mistakenly counted zero errors.

## Decided

The proxy fixture may answer a configured HTTP status after recording a request, without contacting an
upstream. The Dockerfile-fetch scenario uses a deterministic 502 response. Its assertion that the fetch
went through the proxy remains unchanged; the test never promised a successful clone from the example
host. Existing broker tests keep the forwarding proxy and their local fake upstreams.

The runner counts a harness error when a child failed to produce a valid test report, even if
the child's incidental assertion totals claim zero errors. Its failure exit status already held.

## Scenario list

- With egress configured, the Dockerfile fetch reaches the configured proxy even when the proxy cannot serve the upstream.
- The existing broker proxy scenarios still forward requests to their local fake upstreams.

## Tests altered

`BuildFromRepositoryTest`, "with egress the Dockerfile fetch goes through the proxy", changes only the
fake's response configuration. No product behavior or acceptance assertion is loosened. This is a
shaper-side harness repair required to finish the requested full acceptance run.
