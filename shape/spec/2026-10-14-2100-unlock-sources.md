# 2026-10-14 21:00 — Unlock sources

The unlocking values (what `secrets.unlock` in `farmy.yml` names: an Infisical token, a client id
and secret) are the one thing farmy has to obtain on the host before it can ask a provider for
anything. The shim read them from the macOS Keychain under a fixed service name, from `secret-tool`
with the same names, or from a command given the name as an appended argument, and asked otherwise.
This record makes the sources equivalent and explicit, names them with one configurable prefix,
makes a locked store a thing the shim handles, and gives the Infisical provider a second way in.

## The rule, stated first

**farmy never stores a secret on disk.** The shim obtains the unlocking values from one source,
and every source is equivalent: the macOS Keychain, the Linux secret service (`secret-tool`), a
command, or a prompt. Providers (`env`, `infisical`, your own) turn unlocking values into secrets.
The guide states this rule first; the Keychain and the secret service are two bullets under it,
not the model.

## Decided

- **One source, chosen by what is there.** `FARMY_UNLOCK_COMMAND` when it is set; else the
  Keychain when `security` is on the PATH; else the secret service when `secret-tool` is on the
  PATH; a name the source does not have is asked for with a hidden prompt on the terminal. Without
  a terminal the name is left out, named on stderr, and the command goes on: farmy then reports
  the routes as `locked`, as it already does.
- **Lookup names.** One configurable prefix, `FARMY_SECRET_PREFIX`, default `farmy/`, used the
  same way by both stores: Keychain `security find-generic-password -s <prefix><NAME> -w`,
  secret service `secret-tool lookup farmy <prefix><NAME>`. The old forms stay accepted and are
  tried second: `-s farmy -a <NAME>` and `secret-tool lookup service farmy account <NAME>`.
- **Locked stores.** A locked Keychain (`security` exits 36, "User interaction is not allowed")
  makes the shim run `security unlock-keychain` once, on the terminal, and ask again. A locked
  secret service collection cannot be unlocked from a shell: the tool's message is shown and the
  value is asked for instead.
- **Unlock commands get the name as `$1`.** `FARMY_UNLOCK_COMMAND` is a shell line, run in the
  containers folder with the name as `$1` (`pass show farmy/$1`), never by string concatenation. A
  line that does not mention `$1` gets the name appended as its last argument, which is what the
  old contract did. The command prints the value; a non-zero exit or nothing printed is "not there".
- **Universal auth for the Infisical provider.** `--client-id-from <unlock name>
  --client-secret-from <unlock name>` in the provider's arguments, optional `--domain <url>`. The
  provider exchanges the two with `infisical login --method=universal-auth --plain`, the id and the
  secret in the CLI's environment and never on a command line, and uses the printed token as
  `INFISICAL_TOKEN` for every `secrets get`. `INFISICAL_TOKEN` under `unlock:` stays as the other
  way in. A login Infisical rejects is the provider's error form: `provider failed`, text not shown.
- **Adding an entry, as the guide shows it.** macOS: `security add-generic-password -a "$USER"
  -s farmy/GIT_TOKEN -w -T /usr/bin/security` (the `-T` lets `security` read it back without a
  dialog); Linux: `secret-tool store --label='farmy GIT_TOKEN' farmy farmy/GIT_TOKEN`.

## Left out

- A long-lived agent in the control container that keeps the unlocking values between commands.
- Changing which commands obtain the values: still the ones that load the brokers (`start`,
  `restart`, `rebuild`, `keys reload`).

## FORMATS.md

- The Unlocking paragraph: the rule, the sources in order, the names, the locked stores, the
  command's `$1`, the guide's shape and its add commands.
- The Infisical provider's universal auth.
- The fakes: a fake `security` and a fake `secret-tool` the kit puts on the PATH per test; the fake
  `infisical` learns `login --method=universal-auth --plain`.

## Tests

- `test/support/fakes/stores/security`, `test/support/fakes/stores/secret-tool`: the two stores
  as programs, with a locked state, a log of their calls, and the real tools' exit codes.
- `test/support/unlock.rb`: `shim_workspace`, `keychain`, `secret_service`, `unlock_command`,
  `assert_store_asked`, `assert_passed_to_farmy`, `refute_passed_to_farmy`, `assert_guide_says`.
- `unlock_test.rb` (new): the shim as a program, through the fake docker.
- `providers_test.rb`: universal auth.
- `docs_test.rb` (new): the guide.

## Scenario list

unlock_test.rb
- the Keychain on the PATH yields an unlocking value under the prefixed name, and farmy receives it on stdin
- the secret service on the PATH yields it under the attribute farmy with the prefixed name
- FARMY_SECRET_PREFIX changes the name looked up in the Keychain
- FARMY_SECRET_PREFIX changes the name looked up in the secret service
- an entry in the old Keychain form, service farmy and account NAME, is still found
- an entry in the old secret service form, service farmy and account NAME, is still found
- a locked Keychain is unlocked once with security unlock-keychain, then every value is read
- a locked secret service is reported as locked, and the value is asked for instead of read
- a name the store does not have is asked for on a terminal; without one it is left out and start goes on
- FARMY_UNLOCK_COMMAND is a shell line run in the containers folder with the name as $1
- an unlock command that does not mention $1 gets the name as its last argument
- the unlock command is the source when it is set, even with a store on the PATH

providers_test.rb
- providers/infisical with --client-id-from and --client-secret-from logs in with universal auth and uses the token for every get, with nothing on a command line
- providers/infisical passes --domain to the login and to every get
- providers/infisical with an identity Infisical rejects reports provider failed and shows nothing

docs_test.rb
- the credentials guide states that farmy never stores a secret on disk, and shows how to add an entry to both stores
