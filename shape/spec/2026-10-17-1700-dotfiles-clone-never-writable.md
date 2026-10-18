# The shared dotfiles clone is never writable in an app, and older images never get a mode

On the owner's machine the shared dotfiles clone (farmy-shared/dotfiles) was found modified: its
.gitconfig held farmy's own git settings (an insteadOf for the forge, a core.sshCommand through
egress-gate:9182, safe.directory /workspace). Two faults together (read-only investigation of work/):

1. Every farmy from 1fb4208 up to 51fd8bb had the app entrypoint drop to dev with HOME=/home/dev and run
   `git config --global` for exactly those settings; ~/.gitconfig is a link into the clone, so git wrote
   through it. Current entrypoints write `--system` only, but current farmy still runs
   `farmy-entrypoint --git-config` in every running app after applying dotfiles, and an image from before
   that flag runs a normal start, writes the same global settings, and hangs in `tail -f /dev/null`.
2. A current app gets the clone through a read-only subpath (7a40402), but only when dotfiles were set
   when its compose was written. An app created without dotfiles, or by an older farmy, mounts all of
   farmy-shared read-write, dotfiles/ included, and `farmy dotfiles pull` still applies links into it.

Decided (the owner, 2026-10-17), before 0.1.0:
- The exec-guard branch (record 2026-10-16-2000) merges into main: an image built by an older farmy is
  skipped with "farmy rebuild <name>", never run with a mode. New test: neither dotfiles pull nor start
  runs an aged image's entrypoint with any mode.
- No app container ever gets the shared dotfiles clone writable, whether or not dotfiles were set when it
  was created: the read-only dotfiles submount is always there.
- dotfiles pull (and every dotfiles apply) skips an app whose clone is still writable (a container
  created before the fix), naming `farmy restart <name>`, exits 1, and leaves the clone untouched.

Tests: EntrypointExecTest "an app whose image was built by an older farmy never has its entrypoint run
with a mode, by dotfiles pull or by start"; DotfilesMountsTest (three tests). The kit can turn a running
app into one with the clone writable (dotfiles_mount_made_writable) and switch dotfiles off and on.
