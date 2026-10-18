# 2026-10-13 12:00 — Setup waits for healthy sidecars and has a time limit

A fifth review, after the workbench record, looked at one consequence of "setup runs at every
start": the setup command runs as soon as the clone is there, and it runs until it ends. Two
things followed from that, both real, both now part of the contract.

## What was wrong

- **A setup that never ends hung `farmy start` forever.** The common case is Rails: since 7.2 its
  generated `bin/setup` ends by starting the development server unless `--skip-server` is passed.
  `setup: bin/setup` therefore never returned, and `farmy start` sat in front of a server that was
  started in the wrong place. Nothing bounded the command, and nothing in the docs said so.
- **Setup could run before the sidecars were ready.** The app container's `depends_on` listed the
  fragment's services as a plain list, which makes compose start their containers first and
  nothing more. `bin/setup` runs `db:prepare`; on a cold start Postgres is still booting when it
  does, and the first setup of every Rails service fails. The fragment cannot touch `app`, so only
  farmy can express the wait.

## Decided

- **Health conditions.** For every service of the fragment the app container gets a long-form
  `depends_on` entry: `condition: service_healthy` when the fragment service declares a
  `healthcheck:`, `condition: service_started` when it does not. The broker stays
  `service_started`. Compose then starts the app container, and farmy the setup, only once every
  checked service is healthy. Nothing in farmy knows how to check a Postgres: the healthcheck is
  the fragment author's, and the documented examples carry one.
- **A time limit on setup.** `setup_timeout` in `farmy.yml`, a duration (`2s`, `30m`, `1h`), default
  `30m`. The setup command runs under that limit inside the container (`timeout`, present on
  Debian and on busybox). A setup that runs past it is stopped and reported as not finished within
  the limit, `start` exits 1 and the containers stay up, exactly as a failed setup does.
  The limit is a backstop for a hang, not a setting a project tunes: thirty minutes is longer than
  any first `bundle install`.
- **The Rails example** everywhere reads `setup: bin/setup --skip-server`, with the reason next to
  it, and its Postgres carries a healthcheck.

## Not decided here

- Whether farmy should recognise the Rails trap (`bin/setup` without `--skip-server`) and warn.
  It is knowledge about one framework and belongs in the docs, not in the program.
- A per-service limit. One per containers folder is enough until a project needs more.

## FORMATS.md

- Definition example: `setup: bin/setup --skip-server`, the Postgres healthcheck, the comment on
  when setup runs.
- After the fragment paragraph: the `depends_on` conditions and the time limit.
- `farmy.yml`: six keys, `setup_timeout: 30m`.
- Exit 1: "a setup command that failed or did not finish within the limit".
- The fake docker: `sleep <seconds>` takes that long and `timeout <seconds> …` ends what it wraps
  with exit 124, so a slow setup can be played; a `service_healthy` condition on a service without
  a healthcheck fails `up`, as the real compose does.

## Tests

- `test/fixtures/workspaces/workshop/services/hub.yml`: `bin/setup --skip-server`, a healthcheck
  on postgres (redis has none).
- `test/support/farmy.rb`: `assert_waits_for name, service, healthy:`.
- `compose_test.rb`: "the app container waits for a fragment service with a healthcheck to be
  healthy, and for the others to be started".
- `commands_test.rb`: "a setup that does not finish within setup_timeout is stopped, reported, and
  start exits 1 with the containers up".
- `integration_test.rb`: the same against the real Docker on a Debian slim image, which proves
  that `timeout` is there.

## Scenario list

compose_test.rb
- the app container waits for a fragment service with a healthcheck to be healthy, and for the others to be started

commands_test.rb
- a setup that does not finish within setup_timeout is stopped, reported, and start exits 1 with the containers up

integration_test.rb
- a setup that runs past the limit is stopped on a real Debian image
