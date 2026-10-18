# Mini regressions: personal Git config, control caching and unknown provenance

The owner reported three concrete failures and requested their fixes and regression tests.
This continues farmy-workbench. The requested outcomes authorize the scenarios below;
no publishing decisions or live publication are included.

Farmy writes its Git defaults to system scope, either /etc/gitconfig or a farmy-owned
GIT_CONFIG_SYSTEM file. A personal ~/.gitconfig, including a link into the read-only
dotfiles repository, belongs to the user. Personal identity and preferences take priority.
Managed insteadOf routes and core.sshCommand remain effective, including conflicting
personal transport settings; verify actual Git URL and SSH behavior as well as config scope.

Normal local init must compare all control build inputs, not merely farmy.version or the
previously compiled binary's hash. Changing a copied resource at the same release version
must rebuild and replace the stale control container. Content, added/deleted input names,
file modes, symlinks, Docker recipes and applicable ignore rules participate. Unchanged
inputs reuse the existing image. Hashing failure must never become a reusable empty hash.
The worker investigates the cause without exposing implementation to the shaper.

An existing app image without farmy.version is reported as
`built by an unknown farmy: farmy rebuild <name>`. JSON retains toolbox_version: null and
sets toolbox_outdated: true so the TUI carries the same actionable warning. An unbuilt
service is not an existing unknown image. The existing older/current/newer version rules stay.

## Regression scenarios

1. A read-only dotfiles-linked .gitconfig survives entrypoint setup and restart byte-for-byte,
   while farmy's Git defaults are readable at system scope.
2. A personal Git identity and ordinary preferences override farmy's defaults.
3. A token route still resolves through the broker despite a conflicting personal rewrite.
4. An SSH route and managed proxy command remain effective despite personal transport settings.
5. Normal init with unchanged local inputs builds once and retains its control container.
6. At an unchanged VERSION, changing each category of control build input makes normal init
   rebuild and replace its control container without FARMY_BUILD=1.
7. Adding or removing a nested build input, changing its executable mode or symlink target,
   and changing Docker ignore rules each invalidate the local control cache.
8. Status for an existing unlabeled app image gives the exact unknown-farmy rebuild warning.
9. JSON for an existing unlabeled app image reports null version and outdated true.
10. A stopped app with an unlabeled image still reports the warning, while a never-built service does not.

The old ShimTest changed a stored hash without changing source; retain it as coverage of a
mismatched label and add real input mutations. IntegrationTest's two Git transport queries
must stop requesting --global: managed transport is now a system/default plus effective-policy
contract. Keep tests of ordinary user precedence separate from managed transport precedence.

Tests exercise the executable shim against a synthetic build context and fake Docker, and
the emitted app scripts against real Git with a read-only linked configuration. Real Docker
integration remains separately reported when a daemon is available. No secrets or private
machine details enter the record, fixtures or diagnostics.
