# Exact public identity exceptions

The owner has supplied a public GitHub owner and maintainer identity for release.yml,
with a placeholder noreply account number that the owner will replace. That public name
also matches a term in the private denylist. The owner requests tests and implementation
that permit the configured identity only in release metadata, author/committer/tagger
fields and the root LICENSE copyright attribution, while continuing to refuse it in
ordinary contents, paths and commit messages. Public values are recorded in release.yml;
this record, fixtures and test names use generic examples.

The owner also explicitly permits exact configured public URLs in root README.md and
CONTRIBUTING.md links. Names in prose, paths and messages remain denied. This resolves
the earlier publishing contract's required GitHub issue, proposal and release-asset links.
The URL exception includes the configured repository/intake URLs and the prescribed
installer/checksum asset URLs derived from the configured GitHub URL and release version.
It does not permit arbitrary URL suffixes or exempt the rest of a line containing a URL.

## Scope

One active public configuration supplies the allowed name/email pair and URLs. The tree
scan uses the working-tree configuration; --staged uses the staged configuration, so
unstaged edits cannot change what staged bytes mean. History uses the current release
configuration, not a separate allowance chosen by each historical commit. A historical
commit cannot authorize a different denied identity by changing its own release.yml.

Only the known identity/URL scalar values in work/release.yml are release metadata:
owner, maintainer_name, maintainer_email, github_url, issues_url and contributions_url.
Comments, contribution_text and other content remain scanned. Commit author, committer
and annotated-tag tagger must match the complete configured name/email pair, with their
normal timestamp fields; messages are never metadata exceptions. The root LICENSE
exception is the exact configured maintainer name on its copyright line, with an optional
standard copyright year/year range. Additional denied text on that line remains a hit.
No blanket removal of a name, email, URL prefix, YAML line or copyright line is permitted.

Tree, staged and history scans, publication and the ordinary repository privacy test use
the same policy. Missing-denylist behavior remains as previously agreed: the ordinary
suite skips for strangers; publication fails closed. There is no live push in this task.
The earlier unbuilt Dockerfile edits remain untouched and uncommitted.

## Scenarios

1. Working-tree, staged and history scans each accept the exact configured public identity,
   its named release metadata, exact LICENSE attribution and permitted public document URLs.
2. Publishing with that denied public identity succeeds and emits the exact configured
   author, committer and annotated-tag tagger without exposing private development history;
   a later release still accepts the same identity and earlier installer links in history.
3. The denied name in an ordinary file, a path, document prose, a URL outside the permitted
   documents, or an unconfigured URL suffix is refused with the offending location.
4. The denied name in release prose or a release-config comment is still refused.
5. Extra denied text on the LICENSE copyright line or in its body is still refused.
6. A commit message or tag message containing an identity-shaped line remains denied.
7. Author, committer and tagger metadata with the configured name but a different email
   are refused rather than receiving a partial-name exception.
8. An older commit cannot excuse its denied identity through its own different configuration.
9. The staged scanner uses the staged release identity even when the working copy differs.

These are the owner's requested success/refusal cases and boundaries of the explicitly
accepted exceptions. No additional product approval is needed before writing them.

## Existing tests changed

PublishingDefaultsTest no longer requires owner and maintainer placeholders: the owner has
now supplied them. Default registry/source and documentation checks compare artifacts with
the declared release configuration so tests do not copy the denied public name into code.
Generic fixtures still assert concrete identities and URLs. ReleaseTest and InstallationTest
retain their default-registry/source behavior with the configured public identity. The
ordinary NothingPrivateTest invokes the shipped scanner so its exception policy cannot
diverge from staged scanning and publication; its absent-denylist warning remains intact.
