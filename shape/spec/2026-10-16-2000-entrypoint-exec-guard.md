# Entrypoint execs never hang and never fail without a cause

On the owner's machine `farmy dotfiles pull` hung: it ran `docker exec -u 0 <app>
/usr/local/bin/farmy-entrypoint --git-config` in a container whose image predates --git-config; the
old entrypoint ignored the flag, started normally and ended in `exec tail -f /dev/null`, so the exec
never returned. Once the process was killed the report read "[<app>] dotfiles/home installer failed: "
with an empty cause.

## Decided (the owner, 2026-10-16)

1. Before an exec into a service container that relies on an entrypoint mode, farmy checks that the
   container's image supports it (its labels, or a capability probe that cannot hang). If not, the
   container is skipped with `[<name>] built by an older farmy: farmy rebuild <name>` and the exec is
   not run. The command still updates every other container, and exits 1.
2. Every such exec has a time limit, 60 s by default; `FARMY_EXEC_TIMEOUT` (seconds) sets it (the
   tests' handle). On expiry the exec is stopped, inside the container as well, and reported as timed
   out with its command.
3. A failure line always carries a cause: the exit status and the last lines of stderr; with no
   stderr, the exit status alone. Never an empty cause.

## Scenarios

- dotfiles pull skips an app whose image was built by an older farmy, naming farmy rebuild, without
  running the entrypoint mode (the old image: an older farmy.hash and an entrypoint that ignores modes
  and ends in tail -f /dev/null; the other app is still updated).
- An entrypoint mode that does not return within FARMY_EXEC_TIMEOUT is stopped and reported as timed
  out with its command, and nothing it started is left running.
- A failed entrypoint mode is reported with its exit status and the last lines it wrote to stderr.
- A failed entrypoint mode that wrote nothing to stderr is still reported with its exit status.

The dotfiles fixture's install.sh learned two triggers for this: ~/fail-dotfiles-quietly (exit 12,
no output) and ~/hang-dotfiles (sleep 600).
