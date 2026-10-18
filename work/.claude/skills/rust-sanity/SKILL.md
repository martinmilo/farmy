---
name: rust-sanity
description: Apply and uphold this project's Rust baseline (lints, bin/check, GUIDE.md) when creating a Rust crate, refactoring one, or fixing what bin/check reports. Use for "run the checks", "make clippy pass", "set up lints", "structure this crate".
---

# Rust sanity

The project carries its own copy of the baseline from `sanity/rust`. Work from the
project's copy, never from the original: the team may have adjusted it.

## Where things are

- `Cargo.toml` at the workspace root: the `[workspace.lints.*]` tables and
  `[profile.release]`. The first comment line names the baseline release.
- `clippy.toml`, `rustfmt.toml`, `deny.toml` next to it.
- `bin/check`: the whole check. Exit 0 is the only pass.
- `./GUIDE.md`, next to this file: the structural rules no lint checks. Read it before
  designing a crate or deciding how to fix a lint finding.

If a project has none of these, it has not adopted the baseline. Say so and stop; copying
the files in is the owner's decision, because `deny.toml` holds policy they must set.

## When asked to make the checks pass

1. Run `bin/check`. Read every finding; the first failing step stops the run, so run again
   after fixing until it prints `==> clean`.
2. Fix the code, not the rule. The section "When the lints flag something" in
   `./GUIDE.md` says what the fix is for each lint. A suppression is
   `#[expect(lint, reason = "...")]`, as "Suppressing a lint" there says, and only when
   the reason is one a reviewer would accept.
3. Never edit the lint tables, `clippy.toml` or `deny.toml` to make a finding go away.
   If a rule is wrong for this project, say which one and why, and leave the change to the
   owner.
4. Report what `bin/check` printed at the end, verbatim, and list every `#[expect]` you
   added with its reason.

## When designing or restructuring a crate

Follow "Shape of a project" and "Keeping the freedom to change an API" in `./GUIDE.md`.
The decisions that come up most:

- A binary crate splits into a library plus a thin `main.rs` only when Rust integration
  tests or another crate import the logic. Tested black-box through its binary, it stays
  one crate with `pub(crate)` internals.
- The domain core has no I/O, runtime or async dependency.
- One error type per crate, `#[non_exhaustive]` on it.
- `pub(crate)` for what the crate does not export; `unreachable_pub` will tell you.
- A service decides its panic strategy and shutdown explicitly; see "Failure, in a service".

## When starting a new workspace

Use the workspace form from `Cargo.lints.toml`: `resolver = "3"`, `crates/*` members,
versions in `[workspace.dependencies]`, `[lints] workspace = true` in every member, and
`#![forbid(unsafe_code)]` in every crate root that will never need unsafe. A command line
binary expects `print_stdout` once, in its crate root, with a reason.
