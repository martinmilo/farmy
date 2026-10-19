# A login turn ends only when its agent container is gone

Factory logins (2026-10-18-2047) give one agent iteration at a time per factory login. The turn is held by
the controller's process. When a controller dies mid-turn (killed, the machine's session closed), its turn
ends with it, but Docker keeps the agent container running: its client died, the container did not. The
next run on that login could then start a second agent on the same login file while the first still
refreshes its token, which is the race the turn exists to prevent.

Decided (the owner, 2026-10-19):

- A login turn ends only when the agent container holding it is gone. If the controller's `docker run`
  returns or fails while that container still exists, the controller removes it before the turn passes on.
- Before granting a turn, the controller stops orphaned agent containers of the same login and records it.
  An orphan is a running container labelled `farmy.role=agent` and `farmy.factory-login=<agent>` whose run
  is one of this containers folder's (`.work/<service>/runs/<id>/` exists) and whose controller is gone (its
  `controller.lock` not held). farmy removes it (`docker rm -f`) and keeps `orphans_stopped` in its own
  run's `state.json`, a list of `{container, run}`; `factory show` says
  `stopped orphaned agent container <name> (run <id>)`.
- Login-mode agent containers carry the label `farmy.factory-login=<agent>`, so orphans are found by label.
- Containers of another factory login, of a live run, or of another containers folder are left alone (the
  turn is per containers folder, as before).

The fake docker now lists an agent container as running while it plays, keeps it running when its client is
killed (as Docker does), and ends its play early when the container is stopped or removed.

Left out: a turn shared across containers folders; stopping orphans that hold no factory login (a dead
run's api-key or token agent goes on until it ends, as today).

## Scenarios (FactoryLoginOrphansTest)

1. A login-mode agent container is labelled with its factory login.
2. A controller killed mid-turn leaves its agent running, and the next run on that login stops the orphan
   before its own agent starts and records it.
3. An orphaned agent container of another factory login is left running.
4. An agent container of the same factory login from another containers folder is left running.
