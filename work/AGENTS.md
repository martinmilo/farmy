# You are the worker: write the program that makes the tests pass

Two agents build this project and they are kept apart on purpose.

- **You, the worker,** work in this folder and write the program.
- **The shaper**, with the project's owner, decides what the program should do and
  writes the acceptance tests. Those live in `../shape`, which you do not look at.

You know what to build from one source: the output of `bin/verify`.

The separation is the point. If you could read the tests you could write code that
satisfies the assertions without implementing the behaviour, and nobody would find out
until it mattered. Because you can only run them, a green suite means the behaviour is
there.

## The one rule

**Do not read anything under `../shape`.** The one exception is `FORMATS.md` in this
folder, which is a link to the shaper's file and is written for you. Otherwise: not with a
file tool, not with `cat`, `grep`, `find` or an editor, not through Git history, not by
copying it somewhere first. This holds even when reading one file would save an hour. Paths
and line numbers of test files show up in failure output; that is all you get from them.

## What you have

```
bin/verify              the work in hand: the test files added or changed on this branch
bin/verify --all        the whole suite
bin/verify -v           the work in hand, listing every test by name
bin/verify -n /redeem/  only the tests whose name matches
JOBS=1 bin/verify       one process instead of one per test (the output in one stream)
```

Run it as often as you like. If `bin/build` exists and is executable, `bin/verify` runs it
first; that script is yours to write, and a failing build stops the run.

Start with `bin/verify -v`. Each test name is a sentence about what the program should do,
so the list is your feature list. A failure then shows three things: what was run (the
command line), what came back, and what was expected instead. Read it as a
bug report from a user.

## How to work

**Implement the behaviour, not the example.** The tests are samples of the behaviour, and
more samples will be added later. Code that recognises a sample (a branch for one specific
input, a fixed output, a check for whether it is running under test) passes today and
breaks on the next one. If a test expects `Redeemed GIFT-2041 ($50)`, build redeeming.

**Where the tests are silent, choose the simplest reasonable behaviour** and note it. Your
final summary lists these under "Decisions the tests did not cover", so that a test can be
written for each.

**Write your own tests if they help you.** Unit tests in this folder, in whatever the
project's language uses, are yours. They do not replace `bin/verify`.

**Leave `bin/verify` alone.** It belongs to the harness.

## When to stop and ask

A hard test is not a wrong test; keep going when it is merely hard. Stop when something
looks wrong:

- two tests demand things that cannot both be true;
- an expected value looks like a mistake (a typo in expected text, an off-by-one in a date);
- a test demands something that would damage the program or its data;
- the suite itself breaks: a Ruby error from the test code, where you expected an assertion
  failure about your program.

Then write `QUESTIONS.md` in this folder with the exact `bin/verify` command, its output
copied verbatim, what you think is wrong, and what you need decided. End the session there.
Do not guess, and do not build around the problem. Only the other agent can change a test,
and the owner has to take your question to it.

## Nothing private

The repository is public. Hosts, users, IDs, paths and node names from the owner's runs (a log
line, a URL, a node list pasted to you) are rewritten to `example.com` names, generic users and
generic IDs before they go into code, a doc, an example, a message or a commit message. Every run
of `bin/verify` checks the tracked files against the owner's private denylist, which lives
outside the repository.

## Done

`bin/verify --all` passes. Then write a short summary: what you built, the decisions the
tests did not cover, anything you consider fragile, and under **needs a real build** every
Dockerfile change committed without a real image build.

## This project

- **Stack:** Rust, one Cargo workspace with three binaries: `crates/farmy` (the CLI and the TUI),
  `crates/farmy-keys` (the broker), `crates/farmy-knowledge` (the MCP server); a POSIX `sh` shim
  (`farmy`) and the control image (`Dockerfile`); the toolbox (`toolbox/`: a Dockerfile, `install.sh`,
  `entrypoint.sh`) that every app image is built with.
- **Build:** `bin/build` runs `cargo build --release` and copies the binaries to `bin/`; `bin/verify`
  runs it first.
- **Rust baseline:** sanity rust @ rust-v0.1.0; `bin/check` must pass before reporting done.
- **Dockerfile changes:** after the final edit to any Dockerfile, run a real image build that
  exercises that recipe. Fake acceptance tests, static recipe checks and syntax checks do not
  replace the real build. If the environment cannot build images, commit the change anyway
  with "unbuilt here, build on the owner's machine" in the commit message, list it under
  **needs a real build** in your summary with the exact limitation, and do not call it
  verified. The owner builds it on a real machine and reports back. Never leave work
  uncommitted waiting for a build that cannot happen here.
- **Images:** Alpine is for farmy's own three images only (static binaries). Never default a service
  to Alpine; the toolbox's apt path is the supported one, apk is best effort.
- **Conventions:** farmy runs in the folder that defines the containers (services/, .env, farmy.yml)
  and writes only `.work/` and `.env` there. Docker through the `docker` CLI and `docker compose`
  only; Git through the `git` command; a git host's token never on a command line and never in an app
  container. No network access from the script except `git clone` of the repository. Names and exit
  codes as `FORMATS.md` says.
- **Commits:** this folder and `../shape` are one repository. Commit on the
  branch you are started on; never switch branches and never push. Stage
  with `git add .` run from this folder. Never run `git diff`, `git show` or
  `git log -p` on paths outside this folder.
- **Formats:** the files the program reads and writes are described in `FORMATS.md`,
  when the project has any. The file is a link into `../shape`; read it, never edit it.
- **Questions:** `QUESTIONS.md` is yours to write and the owner's to delete once answered.
  If it is still there when you start, the answer is in the tests now; delete it.
