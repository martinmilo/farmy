# 2026-10-13 13:00 — The Infisical provider, for real

farmy ships two providers next to itself, `providers/env` and `providers/infisical`. The second
wraps the `infisical` CLI, and nothing had ever run it: the control image did not contain the
CLI, so the provider answered with the protocol's error form on every machine. The owner's real
setup is Infisical with one unlocking token, so this has to work before step 3 of the first run.

## Decided

- **The control image carries the Infisical CLI.** `farmy:local` has `infisical` on its PATH.
  That is the one third-party tool in the control image besides docker, git and tmux; a provider
  that needs anything else is the owner's own program.
- **Where a provider is found.** `secrets.provider` names a program and its arguments, run as
  given, no shell. A relative path is looked for in the containers folder first and then in
  farmy's own folder, so `providers/env` and `providers/infisical` work by those names from any
  containers folder, and a provider of your own at `bin/provider` wins over nothing.
- **What the Infisical provider does.** It asks the CLI for each secret by name, as
  `infisical secrets get <NAME> --plain <the arguments from farmy.yml>`, with the unlocking value
  (`INFISICAL_TOKEN`) in the CLI's environment; a secret the CLI does not have is `missing`; a CLI
  that is not installed is the protocol's error. No value is written anywhere.
- **The protocol's error form is a provider failure.** A provider that exits 0 with
  `{"version": 1, "error": "…"}` is treated like one that crashed: its routes read
  `provider failed`, start goes on, the text is not shown. This was in FORMATS and in no test.

## Not decided here

- The `.env` cleanup (`repo:` always a full URL, several git routes keyed by host) and the agents
  record both wait for the first run.

## FORMATS.md

- The provider example reads `providers/infisical` with its arguments; the resolution rule.
- The control image's contents name the Infisical CLI.
- The fake `infisical` on the tests' PATH.

## Tests

- `test/support/fakes/bin/infisical`: answers `secrets get <NAME> --plain …` from
  `FAKE_INFISICAL_SECRETS`, logs its arguments and `INFISICAL_TOKEN` to `FAKE_INFISICAL_LOG`.
- `keys_test.rb`: the error form.
- `providers_test.rb` (new): the two shipped providers as programs, through farmy.
- `integration_test.rb`: the CLI is in the control image.

## Scenario list

keys_test.rb
- a provider that answers with the protocol's error form has its routes read provider failed, and the error text is not shown

providers_test.rb
- providers/env answers with the unlocking values farmy was given and reports the rest missing
- providers/infisical asks the infisical CLI for each secret with the arguments of farmy.yml and the unlocking token in its environment
- providers/infisical reports a secret the CLI does not have as missing

integration_test.rb
- the control image has the infisical CLI
