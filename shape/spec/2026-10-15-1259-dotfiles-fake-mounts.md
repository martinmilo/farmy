# Dotfiles fake filesystem and Git boundaries

The worker's first runtime check exposed test-harness errors after valid Docker volume mounts were
submitted: overlapping read-only paths left the fixture unwritable during cleanup, and a named volume
mounted at /home/dev was not represented by the fixture's home alias. The fake must preserve original
permissions across overlapping paths and model persistent home mounts, while continuing to execute
the submitted home script itself. It must not manufacture the dotfiles or shared-data links.

The fake's Git boundary must handle a repository URL supplied through environment variables as well
as arguments. It authenticates against the configured fake token/SSH route before forwarding to the
local bare repository. Clone/pull observations must describe actual Git invocations, not commands
present in an unexecuted branch of a submitted shell script.

The private-login assertion now accepts the tool-data subpath itself as well as its descendants.
That folder exposes no login directories. Whole farmy-shared mounts remain forbidden for private
logins; the existing login-volume and HOME isolation assertions retain their meaning. These are
harness corrections to the approved behavior, not new product decisions or reduced assertions.

The DotfilesInstallerTest restart scenario also now issues `farmy restart`, as its name and approved
start contract intend. Its original second `farmy start` merely ensured an already-running app was up,
so it did not exercise another container start. The expected second installer invocation is unchanged.
