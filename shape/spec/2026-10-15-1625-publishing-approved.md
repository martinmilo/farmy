# Publishing decisions accepted; GitHub receives proposals

The owner accepted PUB1–PUB9 from the 12:22 publishing record and directed tests followed
by the worker on farmy-workbench. Keep work/ and shape/ in the public tree, including the
acceptance tests and spec records. Release configuration ships placeholders for the owner,
URLs and maintainer identity; the owner fills them in. This authorization continues the
current branch and covers implementation and local verification, not a live publication.

PUB10 is superseded: the public Forgejo repository sits behind a mesh and cannot receive
internet issues or contributions. GitHub issues are enabled. GitHub PRs are welcome as
proposals; maintainers apply accepted changes in the source repository, include them in
the next release, and credit contributors in release notes. README and CONTRIBUTING say
this plainly. An optional workflow comments that policy on new PRs; enabling it does not
run code from a proposal or merge/close it. No comments are sent during this work.

## Concrete public contracts

work/release.yml is the single declarative public release configuration. Its fields are
owner, github_url, public_remote, maintainer_name, maintainer_email, issues_url,
contributions_url and contribution_text. The owner supplies the GHCR namespace; registry
is ghcr.io/<owner>/farmy, preserving farmy-control, farmy-keys, farmy-knowledge, farmy-gate.
Shipped examples use your-owner, https://github.com/your-owner/farmy, public, and
farmy maintainers <maintainers@example.com>. They are placeholders, not discovered values.
public_remote names a Git remote; its transport URL/credentials remain in private Git config.
Compiled/runtime artifacts derive their defaults from this configuration at build time.
The exported README and CONTRIBUTING render configured intake URLs and contribution text.
Public work/releases/VERSION.md notes carry contributor credit independently of the squashed
commit identity; the workflow publishes those notes with the release assets.

work/public-files.txt is a reviewed export allowlist: one repository-relative file or
directory prefix per line, blank lines and # comments ignored. Include the manifest and
configuration, runtime build inputs, root public docs/licence/workflows/scanners, shape's
acceptance tests, spec records and shared contracts. Do not export the private checkout's
.git, generated state, compiled binaries, target/, local environment or internal notes.
Export committed bytes and executable/symlink modes, not ambient working-tree files.
Retain a safe symlink only when its final target is inside the exported tree and exists.

Root bin/publish VERSION operates on the Git repository containing cwd (root or work/),
using that repository's committed release configuration and allowlist. Exact stable
MAJOR.MINOR.PATCH must match work/VERSION. Refuse dirty tracked input. Prepare an isolated
public repository with no private refs/alternates. The first public commit is parentless;
later commits have exactly the fetched public main tip as parent. Use configured public
author/committer/tagger and neutral version messages, without private commit IDs or text.
Both root scanners run against the candidate; publication requires a readable nonempty
FARMY_PRIVATE_TERMS denylist and fails on any hit or scanner error. Scan complete reachable
public content, paths, commits and annotated tags, including unchanged historical material.
The existing narrow LICENSE copyright exception remains. Ordinary suite skip policy stays.

Push exactly main and vVERSION together with an expected old tip. Refuse an unexpected
history, race, unsupported atomic push, older version or conflicting existing version.
An identical already-published version is a successful no-op. Retrying failed publication
adds no duplicate release commit. Success describes Forgejo publication only; it never
claims that GitHub mirroring, image publication or release assets completed.

The actual root .github/workflows/release.yml handles push tags v*. Native ubuntu-24.04
and ubuntu-24.04-arm jobs build four roles, push architecture digests with GITHUB_TOKEN,
and pass all eight digests to manifest jobs. Publish <version> and latest only after all
native builds succeed; release assets wait for all manifests. Assets are install and
SHA256SUMS, the latter covering exactly the attached installer bytes. README documents
the GitHub asset URL and verification; standalone fallback is <github_url>.git#vVERSION:work.
The real workflow is validated on GitHub, not simulated as a successful registry release.

The optional root .github/workflows/mirror-pr.yml handles newly opened proposal PRs using
trusted base-repository policy only. Default off; repository variable FARMY_PR_NOTICE=true
enables its comment. It needs comment permission, never checks out/executes the PR head,
and explains mirror status, maintainer application, next-release delivery and credit.

## Accepted scenarios to test

PUBS1–PUBS20 remain as approved in the original record. PUBS21 now checks GitHub issues,
proposal PRs, next-release delivery and contributor credit, with no Forgejo intake.
The following sentences expand those approved behaviors into independently readable cases:

1. Default installer, shim, helper images, update and release use the configured GHCR namespace.
2. Explicit registry/source overrides remain effective.
3. Standalone failed pulls use the GitHub mirror's matching tag and work/ context.
4. Release configuration retains documented placeholders rather than private identities.
5. README links the installer asset and documents SHA-256 verification.
6. The native workflow declares v* tags, all four image roles and both matching runners.
7. Build/push jobs use GITHUB_TOKEN and the required minimal permissions.
8. Digest artifacts distinguish every role/architecture and all builds gate every manifest.
9. Version/latest manifests use digests and all manifests gate installer/checksum release assets.
10. The first publish creates one parentless public commit while private history stays unreachable.
11. A later publish adds exactly one child of the prior public main despite several private commits.
12. Export includes allowed runtime source, acceptance tests and spec records with original modes.
13. Export excludes non-allowed private files, local state and compiled products.
14. Safe internal symlinks survive; dangling or escaping symlinks refuse with no remote changes.
15. Public author, committer and tagger use configured identity despite ambient Git identity.
16. Public messages contain the version and no private commit IDs or development messages.
17. Privacy hits in current content, names and symlink targets prevent every ref update.
18. A hit in an old public commit's content or metadata prevents the next publication.
19. A hit in annotated tag metadata prevents the next publication.
20. Missing, empty or unreadable denylist and a failing scanner each refuse without a push.
21. Version syntax errors, VERSION mismatch and dirty tracked input name the reason and preserve refs.
22. Identical repeat publication is a no-op, while changed content or public metadata conflicts.
23. Older releases and unexpected public history are refused without rewriting public refs.
24. A remote update during publication and an unsupported atomic push cannot partially publish.
25. A rejected push can be retried with exactly one release commit and no duplicate history.
26. Publishing changes only the chosen remote's main/tag and preserves private refs, index and files.
27. Publication reports Forgejo success separately from unverified GitHub synchronization and CI.
28. README and CONTRIBUTING direct issues and proposal PRs to GitHub and explain application/credit.
29. The optional PR notice is disabled by default, targets opened PRs and has comment permission.
30. The notice uses trusted policy, has no PR-head execution, and states all contribution promises.
31. Exported public docs render the configured GitHub URLs and contribution policy.
32. Explicit contributor credit survives in exported version notes and is used by the release workflow.

Existing ReleaseTest's missing-registry refusal becomes default-GHCR success. InstallationTest's
missing-source refusal becomes default GitHub-tag fallback. Explicit overrides and release
version/refusal checks retain their meaning. No behavior of ordinary development caching changes.
