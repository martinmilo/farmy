# Rust structure guide

What no linter checks. `Cargo.lints.toml` and `bin/check` enforce the rest; this file is for
the decisions you make before the first line of a crate exists, and when the lints flag
something and you need to decide what the fix is.

## Shape of a project

- **Virtual workspace under `crates/`.** One `Cargo.lock`, every version in
  `[workspace.dependencies]`, every member on `[lints] workspace = true`. Set `resolver`
  explicitly; a virtual workspace has no edition to infer it from.
- **Thin binary, fat library, once something imports the logic.** When Rust integration
  tests or another crate need to call into the program, `main.rs` parses configuration,
  initialises logging, wires the dependencies and calls into a library crate. A bin-only
  crate that is tested black-box through its binary does not split: its internals are
  `pub(crate)`, and that is their correct visibility, not a workaround for
  `unreachable_pub`.
- **A domain core with no I/O.** The crate that holds the rules depends on no runtime, no
  async, no network or database client. Adapters around it do the talking. A crate
  boundary makes the compiler enforce the direction; a module boundary does not.
- **Do not over-split.** A crate is a unit of compilation and of semver. Split at a boundary
  that will stay, not per feature.
- **One error type per crate.** Not one enum shared across the workspace. An adapter crate
  wraps the core's error, it does not extend it.
- **One integration-test binary.** `tests/it/main.rs` with submodules, not one file per
  test under `tests/`. Each file there is a separate link step.
- **The `unsafe` boundary is a crate.** It declares its own `[lints]` instead of inheriting,
  because `forbid` cannot be overridden and the workspace says `deny`. Every other crate
  root carries `#![forbid(unsafe_code)]`.

## Keeping the freedom to change an API

- **`#[non_exhaustive]` on public enums and options structs**, error enums first. Inside the
  defining crate, matching stays exhaustive. Only a downstream crate is forced into a
  wildcard arm. Both rules hold at once.
- **Sealed traits** for a public trait you expect to add methods to.
- **Do not leak a dependency's types** through a public signature. Returning
  `reqwest::Error` or `chrono::DateTime` makes that crate's breaking release yours. Wrap
  it, or expose it on purpose and say so.
- **`#[must_use]` on your own builders, guards and pure functions.** The lint only reads the
  attribute; you write it.
- **Precise capture on `impl Trait` returns in public APIs.** Edition 2024 captures every
  in-scope lifetime by default. Write `impl Trait + use<'a, T>` for what you mean to promise.
- **Async in a public trait**: `fn op(&self) -> impl Future<Output = T> + Send`, not
  `async fn`. A native `async fn` cannot express `Send` for callers and is not usable as
  `dyn`.
- **A published library runs `cargo semver-checks` in CI.** It is the only mechanical check
  that you did not break the API.

## Suppressing a lint

- **Every suppression is `#[expect(lint, reason = "...")]`.** The compiler then reports
  the attribute the day the code no longer trips the lint, so a suppression cannot
  outlive its reason. `allow_attributes_without_reason` refuses either attribute without
  a reason.
- **`#[allow]` only for a lint that fires conditionally**, under a `cfg` or a feature, where
  an `expect` would be unfulfilled in some builds. The reason says which condition.
- **Integration test files whose helpers unwrap** start with
  `#![expect(clippy::unwrap_used, reason = "test helpers; a panic is a test failure")]`.
  Clippy's test allowance covers `#[test]` bodies and `cfg(test)` modules only, so a
  helper method in `tests/` is production code to it.

## When the lints flag something

- **`unwrap_used`**: on a production path, either handle the `None` or `Err`, or write
  `expect("why this cannot fail")`. The reason is for the person reading the panic.
- **`let_underscore_must_use`**: a discarded `Result` is a decision. Write
  `#[expect(clippy::let_underscore_must_use, reason = "...")]` on that statement, with the
  reason best-effort is acceptable there.
- **`cast_*`**: use `From` or `TryFrom`. Where `as` is the right tool, say why in an
  `#[expect]` with a reason.
- **`unreachable_pub`**: `pub(crate)`. Only when a Rust integration test or another crate
  needs the item is the crate missing a `lib.rs` that exports it.
- **`print_stdout`**: the binary crate root expects it once; a library never prints.

## Failure, in a service

A service is a long-running program with a supervisor such as systemd or Kubernetes.

- **Panic strategy is `abort`** in `[profile.release]`. With unwind and an async runtime, a
  panicking task disappears unless something observes its `JoinHandle`, and the process
  stays up in a degraded state. Choose unwind only for per-request isolation you have
  designed, and then observe every handle.
- **Observability.** `tracing` with a span at every operation boundary. An error is logged
  once, at the boundary, not at every layer it passes through. Secrets get a manual `Debug`
  impl or the `secrecy` crate so a derived `Debug` cannot print them. Release keeps
  `debug = "line-tables-only"` so a backtrace names lines.
- **Graceful shutdown is a feature.** Handle the signal, stop taking work, drain what is in
  flight, flush, exit. With Tokio: `JoinSet` for an owned group of tasks,
  `CancellationToken` and `TaskTracker` from `tokio-util` for shutdown, and the per-method
  cancel-safety note in Tokio's docs for anything inside `select!`. `spawn_blocking` has its
  own bounded pool; count it when you bound offloaded work.
- **Mutex poisoning** is a policy question. `parking_lot` does not poison, which is why many
  teams use it; the trade is that a panic mid-critical-section leaves whatever state it
  left.

## Tests

- Failure paths are tested with the same care as success paths. `cargo-mutants` shows
  whether a failure test asserts anything.
- `insta` snapshot tests for transformation and serialisation output.
- A `cargo test --release` lane finds little once overflow checks are on in release; run it
  nightly or in the merge queue, not on every push.
