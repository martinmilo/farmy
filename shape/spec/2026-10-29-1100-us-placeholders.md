# Test data reads as American: names, places, money

The owner, 2026-10-29, on seeing `GIT_USER_NAME=Ines Hartmann` in a test: "adjust the names and placeholders to
fit US stuff". The kit's persona came from the first session and was German (Ines Hartmann, `ines@hartmann.dev`,
an address on a real top-level domain); a few details followed it: `Europe/Berlin` and `Europe/Vienna` as time
zones, euro amounts in `TESTING.md`, a `+01:00` offset on the tests' commits.

## Decided (owner)

- Names, places and amounts in tests, fixtures, examples and docs read as American:
  - the Git identity is **Dana Brooks** / `dana@example.com`;
  - a home is `/home/dana`, or `/Users/dana` on a Mac;
  - time zones are `America/…`;
  - amounts are in dollars (`$50`).
- Addresses and hosts stay on `example.com` (the Nothing private rule). `acme`, `workshop.local` and Emma Clarke
  already fit and stay.
- The work side's docs, examples and code follow the same rule; the worker is told.

## Existing tests that changed (their data only; no test changes meaning)

- Every test that names the Git identity. That covers the `settings` default in `support/farmy.rb` and the
  workshop fixture's `.env`, so in practice every test that uses them.
- Tests that name the identity in their own body:
  - `InitTest` (the identity tests and the `host_git_identity` situations)
  - `StartTest` "starting without .env takes the Git identity from the environment, writes .env with it, and starts"
  - `DefaultHomeTest`, `ShimFoldersTest`, `FolderResolutionTest` "farmy -C . init in a plain folder …"
  - `ConfigHomeTest` "after a no, farmy config git makes the repository …"
- `ShimTest` "the control container gets the host's TZ, so the session's clock is local": `America/Chicago`
  instead of `Europe/Berlin`.
- `IntegrationTest` "the control image has tzdata: a zone in TZ gives a local date": `America/Denver` instead of
  `Europe/Vienna`.
- The tests' own commits are dated `2026-01-15T09:00:00-05:00` instead of `+01:00`.
- `TESTING.md`'s examples give amounts in dollars.
- `FORMATS.md`'s `status --json` example shows `/home/dana`.

## Not changed

- Older spec records. They are history and are not edited; none of them names the persona.
