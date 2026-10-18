# 2026-10-15 07:00 — Cleanups after the first full run

The owner's run is complete: start and rebuild clone a private repository over the mesh with the
key in the broker, push works, and Claude logs in inside a container with the shared login. What
the run left, no new design:

1. **`farmy run` gives git no pager**: the command runs with `GIT_PAGER=cat` and `PAGER=cat` in its
   environment, so `git log` prints and ends instead of paging.
2. **The build collapses on a terminal.** When the shim pipes unlocking values into farmy it cannot
   give `docker exec` a terminal (`-t` needs stdin to be one), so farmy saw none and streamed every
   build line. The shim now passes `FARMY_TTY=1` when its own stdout is a terminal, and farmy takes
   that as a terminal for what it prints (the collapsed build, the live waiting line). The shim's
   side needs a terminal and is not testable here; farmy's side is.
3. **Status shows the egress mode**: the `egress` line ends with `kernel mode` or `userspace mode`.
   The TUI's "as of" is shown in the local time zone (`TZ`, tzdata); the JSON stays UTC. The TUI's
   drawing is not under test.
4. **farmy's own Dockerfile fetch goes through the egress proxy**, like the provider: the proxy
   variables, and for SSH a `ProxyCommand` with `nc -X 5` (the control image gets
   `netcat-openbsd`).
5. **Docs**: "keys stored base64" in the credentials guide; the egress guide's control-server
   lessons with the SSH port.
6. **`docs/first-run.md`** steps 1 to 3 as they ran, generic names, step 3 marked verified.
7. **A login path is linked as what it is.** The entrypoint created every shared login path as a
   folder; `~/.claude.json` is a file, became a folder on `farmy-shared`, and Claude asked for a
   login at every start. A login path ending in `/`, or whose last part has no extension, is a
   folder; one whose last part has an extension (`.claude.json`, `auth.json`) is a file. `agents.tsv`
   writes folders with a trailing `/`, files without; the entrypoint creates a file's shared target
   as an empty file (and replaces an empty folder left there by an earlier farmy).

## FORMATS.md

- `farmy run`'s environment. `FARMY_TTY`. The egress status line. The fetch through the proxy, the
  control image's `netcat-openbsd`. Login path kinds and `agents.tsv`'s trailing `/`.
- The fakes: `docker exec -e` is kept on the exec; `docker build` without `-q` prints a few
  BuildKit-style lines on stderr.

## Tests altered

`agents_test.rb`, "an agent of your own has its login paths linked into farmy-shared…": `.mytool`
is a folder, so `agents.tsv` gives `.mytool/`.

## Scenario list

commands_test.rb
- run gives the command GIT_PAGER=cat, so git does not page

start_test.rb
- with FARMY_TTY=1 a build's output collapses: no build line stays on the screen

egress_test.rb
- the status line names the egress mode

build_from_repository_test.rb
- with egress the Dockerfile fetch goes through the proxy

agents_test.rb
- a login path with an extension is a file and one without is a folder: agents.tsv marks folders with a slash

integration_test.rb
- inside the container ~/.claude.json is a file on farmy-shared and ~/.claude a folder
