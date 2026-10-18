# 2026-10-13 20:00 — First run after mission control: what the Mini found

The knowledge container came up, the hints were gone, BuildKit built, the drift note fired, the
hooks reported `idle` in `status --json`. Five findings, fixed here and nothing else.

## Decided

1. **The keys broker starts and listens, with or without routes, as the user it runs as, on the
   socket it is given.** On the Mini the broker crash-looped after a recreate: `cannot listen on
   /run/farmy-keys.sock: Permission denied`. The broker runs as uid 1001 on a read-only root with
   `/run` and `/tmp` as tmpfs mounts; a tmpfs the daemon mounts root-owned without a mode is not
   writable by 1001. The compose file now asks for those tmpfs mounts with mode 1777 explicitly,
   and the broker names the directory's owner and mode when a bind fails, so the next report is
   precise. Tests: the broker as a program with no routes answers health and has its socket; the
   integration tests start a service with and without routes and check that `<name>-keys` is
   running with no restart, that the socket exists and that the process is uid 1001.
2. **The TUI is the farmy binary, and the session is held to it.** A TUI process lives in the
   tmux session and runs with the binary it was started with; nothing restarted it when the
   binary changed. Now every binary carries a build hash of its sources: `farmy --version` prints
   `farmy <version> (<hash>)`, `farmy tui --version` prints the same, and `farmy session` compares
   the running session's hash with its own and starts the session anew when they differ. A test
   pins that the CLI and the TUI report one hash.
3. **The control image has `tzdata`**, so `TZ` means something and `date` is local. An integration
   test checks that a zone name gives a non-UTC `date +%Z` in the control container.
4. **No tmux keys for the user, ever.** tmux is only how the session survives a closed laptop.
   Actions stream into a scrollable pane inside the TUI (arrows and PageUp/PageDown scroll, Esc
   closes it once the action ended); `e` (shell) and `l` (logs) take the screen over and return
   when they exit; `q` leaves the terminal and keeps the session (tmux detaches, by command, not by
   key); the tmux status bar is hidden. Every "Ctrl-b …" leaves the messages and the docs.
5. **Destroy is `D`.** `d` is the tmux detach reflex; a lowercase `d` does nothing.

## Scenario list

broker_test.rb
- the broker with no routes starts, answers health and listens on the socket it is given

version_test.rb
- farmy --version and the TUI report the same build hash

integration_test.rb
- the keys broker of a service without routes stays up, with its socket, as uid 1001
- the keys broker of a service with routes stays up, with its socket, as uid 1001
- the control image has tzdata: a zone in TZ gives a local date
