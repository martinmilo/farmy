# Completing the approved toolbox coverage

A read-only coverage audit found several assertions that did not fully exercise the owner's already
approved toolbox/dotfiles contracts. This work completes TS7–10, TS17–24, TS28 and TS29; it introduces
no new product behavior and does not inspect the worker's source. The owner already approved those
scenarios and both rounds of answers. The worker continues separately; the shaper records these
coverage corrections first, then updates tests and helpers for coordinated validation.

## Scenario refinements

- A shipped tool's new version with only one replacement artifact is refused rather than inheriting
  other architectures from the old version; a complete replacement matrix is accepted and used.
- Successful bump persists the exact checksum and versioned URL for each of the four fixture
  architecture/libc combinations, and an explicit tool list leaves another locked tool unchanged.
- A managed custom toolbox actually consumes the generated installer after its custom instructions.
  An opted-out custom toolbox executes its own instructions without invoking managed tool downloads
  or installing selected distro packages. The observation follows submitted Dockerfile instructions,
  including continuations, instead of relying on a one-line pattern.
- Dotfile backup files retain the original bytes, including personal files, and an actual restart
  reapplies fallback links without producing another backup or another backup report.
- Architecture, libc and selected-version separation applies to both nvim's local-share directory
  and its cache directory; changing a tool version copies neither old parser nor old cache data.
- Initial clone follows a remote whose default branch is not main. A dirty clone, a rewritten
  non-fast-forward upstream and a changed configured repository URL each refuse pull with the
  reason, preserving the checkout and its applied revision and running no installer.

## Existing tests whose assertions become stronger

ToolCatalogueTest gains partial/complete override cases and observes managed custom Dockerfile
consumption. ToolboxBumpTest checks every pin and preservation outside an explicit selection.
DotfilesTest checks backup contents and uses a real restart for fallback idempotence.
DotfilesInstallerTest adds the three refused-update states. SharedToolDataTest observes cache
separation alongside local share. The existing architecture integration tests retain their explicit
unavailable-Docker/architecture skips; fake observations are not claimed as binary execution.

The shared FORMATS contracts already define these behaviors. The shaper will syntax-check and smoke
the independent harness while the worker is active; the root coordinator runs the focused suite
after a stable worker hold and commits this shaper phase separately.
