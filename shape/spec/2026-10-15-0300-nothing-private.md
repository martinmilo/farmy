# 2026-10-15 03:00 — Nothing private

The repository will be public. Three paths leak the owner's private names: the working tree, the
Git history, and the agents' habit of quoting the owner's runs into records, docs and commit
messages. This record closes the first and the third and gives the owner a tool for the second.

## Decided

1. **A denylist outside the repository**, (a file kept outside the repository; its path was redacted on 2026-10-17, see record 2026-10-17-1600) (one term per line,
   matched case-insensitively; blank lines and lines starting with `#` ignored). It never enters
   the repository, so the list itself is not the leak. The owner fills it.
2. **A test over every tracked file**, `shape/` and the spec records included, reads the list from
   `FARMY_PRIVATE_TERMS` (default that path) and fails naming file, line and term for every match;
   it never prints the line itself. Without the file it skips with a printed warning, so the suite
   stays green for strangers. `test/run.rb` runs it with the work in hand every time, so
   `bin/verify` always does; a pre-commit hook (`.githooks/pre-commit`, enabled with `git config
   core.hooksPath .githooks`) runs the same scan over what is staged.
3. **`bin/scan-history`** at the repository root runs the same list over `git log -p --all` and
   lists the offending commits with where each term is (author, message, diff), for use before
   publishing; squashing, or `git filter-repo --replace-text`, is the owner's call.
4. **The agents' rule**, in `shape/AGENTS.md` and `work/AGENTS.md`: hosts, users, IDs, paths and
   node names from the owner's runs are rewritten to `example.com` names, generic users and generic
   IDs before they go into a record, a test, a doc or a commit message.

## Rewritten

Two matches in the tracked tree: a sample mesh address in the fake docker, now outside the listed
range, and the licence's copyright line. The owner decided the licence keeps naming him: the
copyright line of `LICENSE` is the one line the scan leaves out, in the test and in
`bin/scan-private`; the term stays denied everywhere else. The records were already free of the listed terms. The history is not: every commit
carries the owner's name and address as author, and `bin/scan-history` lists them all.

## Tests altered

None.

## Scenario list

nothing_private_test.rb
- no tracked file holds a term of the private denylist
