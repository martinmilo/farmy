# Publication keeps the README's latest-release links

The 0.1.1 README (2026-10-18-2138) leads with
`curl -fsSL <github_url>/releases/latest/download/install | sh`. `bin/publish` rewrote every installer and
checksum link of the configured repository in the exported README, the `releases/latest/download/…` form
included, to the published version's `releases/download/v<version>/…`. So the public README's one-liner would
have named one fixed release instead of the latest. (Read for the shaper by a read-only work-side helper,
2026-10-19: the rewrite matches `<base>/releases/(latest/download|download/v[0-9.]+)/(install|SHA256SUMS)`.)

Decided (the owner, 2026-10-19):

- `bin/publish` leaves `<github_url>/releases/latest/download/<asset>` unchanged.
- Versioned links, `<github_url>/releases/download/v<x.y.z>/<asset>`, are still rewritten to the version
  being published, whatever version the private README named.

Left out: CONTRIBUTING.md (no release links are rewritten there, as before); other assets.

## Scenarios (PublishingTest)

1. Publication leaves the README's releases/latest/download links as they are.
2. Publication rewrites the README's versioned release links to the version it publishes.
