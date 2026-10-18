# 2026-10-14 25:00 — The login server reaches the node

The owner ran record 2400 on the Mini. The egress node stayed up and the live line worked, but it
asked to register at `https://login.tailscale.com/a/…` instead of the configured control server.
Above it, compose said:

    The "FARMY_JOIN" variable is not set. Defaulting to a blank string.
    The "FARMY_LOGIN_ARGS" variable is not set. Defaulting to a blank string.

The generated compose file put `$FARMY_JOIN` and `$FARMY_LOGIN_ARGS` into the node's command and
the values under `environment:`. Compose interpolates `$NAME` in the whole file from the process
environment of `docker compose`, before any container exists, so both became blank and `tailscale
up` ran without `--login-server`. Record 2300 passed the login server through the image's own
variables and did reach the configured server; 2400 regressed it. The fake did not catch it: it
neither warned about an unset variable nor treated `$$` as compose does.

## Decided

- **A compose file farmy writes holds no variable for compose to fill.** Every value is written
  into the file itself (or a file farmy writes beside it); a `$` meant for a shell inside a
  container is written `$$`. This holds for every compose file under `.work/`.
- **The node's login command carries the login server**: with `egress.tailscale.login_server`
  set, the one `tailscale up` (the container's own, or farmy's with the auth key) has
  `--login-server=<url>` as a word of its own, and no login argument is empty.

## FORMATS.md

- The fake's interpolation: `$$` is a literal `$`; an unset `$NAME` or `${NAME}` without a default
  becomes blank with compose's warning on stderr, `The "NAME" variable is not set. Defaulting to a
  blank string.`
- Mesh egress: the login server is written into the node's command.

## Tests altered

`egress_test.rb`, "a login server of your own is given to the node": it now looks at the login
command (with the auth key: farmy's `tailscale up`) instead of anywhere in the container's
configuration, where a value under `environment:` that the command never received passed it.

## Scenario list

egress_test.rb
- a login server of your own is given to the node: farmy's login command with the key carries --login-server=<url>
- without an authkey the node's own login command carries --login-server=<url>, and compose warns about no variable
- every compose file farmy writes for a start with egress holds no variable left for compose to fill
