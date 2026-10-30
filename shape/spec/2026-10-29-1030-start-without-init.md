# Start without init: the first start writes .env

Follows record 2026-10-29-0926 (a default home). The worker built that record and reported a gap the tests had
not covered. `start`, `restart` and `rebuild` still refuse without a `.env`, pointing at `farmy init`. The README's
three lines (install, `farmy add …`, `farmy`) therefore reach the session, but the first start of a service
fails. The owner's brief says `farmy init` becomes optional and that what a command needs is created on first
use, so this record closes the gap. Chosen by the shaper; the owner may overrule it.

## Decided

- **A command that needs `.env` and finds none writes it, as `init` would, and goes on.** Those commands are
  `start`, `restart` and `rebuild`. The Git identity comes from the first of:
  1. `GIT_USER_NAME` / `GIT_USER_EMAIL` in its environment (the shim passes the host's on every command since
     record 2026-10-29-0926);
  2. the global git configuration where it runs.

  It asks no question, since a start is not where farmy should stop to ask. It writes `.env` the way `init` does
  (`.env.example` with the identity filled in) into the folder in use: the default home's config folder, or the
  project folder. A line on stderr says it was written and where.
- **With no identity anywhere, nothing changes.** The command is refused as today (exit 1, naming `.env` and
  `farmy init`), and nothing is written.
- **An existing `.env` is never changed.** One without the Git identity is still refused by key, as today.

## Existing test that changed

- `StartTest` "starting without .env is refused and init is pointed at" becomes "starting without .env and with no
  Git identity anywhere is refused, init is pointed at, and no .env is written". The situation is the same: the
  suite gives farmy no global git configuration and no `GIT_USER_*`. The new name says why it is refused, and
  the test now also asserts that no `.env` was written.

## Scenario list

1. Starting without `.env` takes the Git identity from the environment, writes `.env` with it, and starts
   (`start_test.rb`).
2. Starting without `.env` and with no Git identity anywhere is refused, `init` is pointed at, and no `.env` is
   written (`start_test.rb`, the changed test).
3. On a fresh machine, a service added with `farmy add` starts without `farmy init`, with the identity the shim
   passes (`default_home_test.rb`).

## Not tested

- The global git configuration as the second source. It is `init`'s existing order, already tested for `init`.
- `restart` and `rebuild`, which follow the same rule as `start`.
