# Contributing to farmy

<!-- farmy-public-policy -->
GitHub is a code mirror. Report [issues](https://github.com/martinmilo/farmy/issues) and submit
[pull requests as proposals](https://github.com/martinmilo/farmy/pulls) there. The public Forgejo
repository sits behind a mesh and cannot accept internet issues or contributions.

GitHub pull requests are proposals. Maintainers apply accepted changes in the source repository for the next release and credit contributors in the release notes.
GitHub proposals are not merged into the mirrored branch. Maintainers apply accepted
changes in the source repository, deliver them in the next release, and credit each
contributor in the release notes.
<!-- /farmy-public-policy -->

Explain the behavior your proposal changes and how it was checked. Acceptance tests and spec
records are public under `shape/`; implementation and its unit tests live under `work/`.
Preserve the shaper/worker separation described by each folder's instructions.

Maintainers record explicit contributor credit in `work/releases/<version>.md`. The release
workflow uses that file; private commit messages and GitHub's automatically inferred authors
are not used to reconstruct credit after squashing.

An optional `.github/workflows/mirror-pr.yml` posts this policy on each new pull request.
It is disabled by default. Set the GitHub repository variable `FARMY_PR_NOTICE` to `true` to
turn it on. It comments using trusted base policy without checking out proposal code, merging
or closing the proposal. Configure the repository's event policy to allow this trusted
`pull_request_target` workflow if GitHub blocks it by default.

## Releasing

Fill the public placeholders in `work/release.yml`, review `work/public-files.txt`, update
`work/VERSION` and the matching notes file, and commit the input before running
`bin/publish <version>` from the private repository root (or `../bin/publish` from `work/`).
The public remote named by the configuration belongs in local Git configuration. Never put
its credentials or the external privacy denylist into the public tree.

See [the release guide](work/docs/distribution.md#public-release-snapshots) for the privacy
checks, isolated history, atomic push, external mirror and native GitHub workflow.
