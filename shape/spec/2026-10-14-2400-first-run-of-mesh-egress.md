# 2026-10-14 24:00 — First run of mesh egress

The owner ran record 2300 on the Mini. The node reached the control server and printed a URL, but
the container exited every 35 seconds (29 restarts in 17 minutes), each start made a new node key,
and no registration ever stuck. Four more things showed on the way. Five decisions, all tested.

## Decided

1. **The node stays up while unregistered, and logs in once.** The container's main process is
   `tailscaled` with one `tailscale up` (with `--login-server` when given) run once beside it when
   no auth key is configured; the container never exits because of the login, and nothing runs
   `up` or `login` again: every call makes a new node key, which is why the URL kept changing. With
   an auth key, farmy's one `tailscale up --auth-key` (the key on stdin) is the only login call.
   A node registered before needs none: its state on the volume brings it back `Running` after a
   restart, without a word. Integration: no restart of the container within 40 seconds while it is
   unregistered.
2. **The registration URL matcher.** The log reads `To authenticate, visit:`, a blank line, then
   the URL alone on a line, indented. farmy reads the container's stdout and stderr (`tailscaled`
   logs on stderr), matches the URL on its own line, and keeps reading the log through the whole
   wait, not once at the start.
3. **Feedback.** While waiting, one live line: `egress: waiting for registration · 2m10s of 10m ·
   <url>` (rewritten in place on a terminal, printed every so often without). `start` shows its
   phases as lines `== <phase>`: `egress`, `secrets`, then per service `images`, `containers`,
   `clone`; the build output stays under its phase, collapsed to its last line on a terminal and
   shown in full when the build fails.
4. **A failed clone ends start.** The entrypoint writes `/workspace/.farmy-clone`: `ok`, or
   `failed` with git's reason on the lines after. `start` reads the content: `failed` ends start
   with exit 1 naming the service and the reason (the container stays up). `farmy add` refuses a
   repository that is not a clone URL as a mistake in the command line, naming it.
5. **`ARG BASE` has a default** in the toolbox Dockerfile (`debian:bookworm-slim`, the supported
   path), so BuildKit stops warning `InvalidDefaultArgInFrom`; farmy always passes `BASE`.

## FORMATS.md

- Mesh egress: the container's command and the one login; the log on both streams, the URL on
  its own line, polled through the wait; the waiting line; the phases; the clone marker; `add`.
- The fakes: a container's log on stderr (`container_log … on:`), and one that appears after a
  number of reads (`after:`).

## Tests altered

`egress_test.rb`: the three tests that counted the registration URL once in stdout now count it
alone on a line once (the instruction block); the live waiting line of decision 3 carries it too.

## Scenario list

egress_test.rb
- the registration URL is read from the node's log on stderr, on its own line under "To authenticate, visit:"
- the log is read through the whole wait: a URL that appears only after a few reads is still printed
- while start waits for registration farmy runs no tailscale up or login of its own: the node's one call is the container's
- with an authkey farmy runs one tailscale up with the key and never another
- a registered node comes back Running after its container restarts, without a word and without a new login
- while waiting, start prints a live line with the elapsed time, the limit and the URL
- start shows its phases in order: egress, secrets, images, containers, clone

start_test.rb
- a clone the entrypoint reports as failed ends start with exit 1 and the entrypoint's reason

add_test.rb
- add refuses a repository that is not a clone URL as a mistake in the command line, naming it

toolbox_test.rb
- the toolbox Dockerfile gives BASE a default, so BuildKit does not warn about it

integration_test.rb
- the egress node stays up while unregistered: no restart within 40 seconds
