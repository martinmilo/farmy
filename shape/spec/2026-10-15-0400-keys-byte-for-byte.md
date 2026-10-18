# 2026-10-15 04:00 — Keys byte for byte

The owner ran the SSH path through the mesh: ssh reached the git host through the proxy and got to
publickey authentication, but the key never reached the broker's agent. The broker logged "loaded 1
secret(s)", then "the SSH agent could not take the key: ssh-add did not accept a key", and still
answered `ok`, so farmy reported the route loaded.

## Decided

1. **Values travel byte for byte.** The shim passes each unlocking value as `NAME:base64=<the value,
   base64>`; farmy decodes it (and still reads a plain `NAME=value` line). The shipped providers
   escape every control character in their JSON answer, so a multi-line value survives. Tested
   end to end: a real OpenSSH key from the unlock command, through the shim, farmy and the load,
   into the broker program, whose agent lists it.
2. **`encoding: base64` on a route**: farmy decodes the provider's value before it loads the
   broker; a value that does not decode leaves the route `rejected`. For an SSH route without it,
   a value that is not a key but decodes to one starting `-----BEGIN` is not loaded, and the route
   reads `rejected (it looks base64-encoded: encoding: base64 on the route)`; the broker says the
   same when `ssh-add` refuses such a value, and answers the load with an error instead of `ok`
   whenever its agent does not take a key.
3. **Loaded is what the broker holds.** `farmy-keys loaded` prints the names of the secrets the
   broker holds (an SSH key only once its agent took it). `farmy keys` asks the running brokers: a
   route is `loaded` when a broker of a service it is granted to holds its secret; one that farmy
   loaded but no broker holds now (made anew, restarted) reads `not loaded (farmy keys reload)`.
   Every start, restart and rebuild loads the brokers it made.
4. **`FARMY_UNLOCK_COMMAND`** is read from `.env` like the prefix (the environment wins). A failed
   clone's reason keeps the decisive line: the entrypoint writes git's last twenty lines into the
   marker, and farmy names the first line that says why (`Permission denied`, `Host key
   verification failed`, `Could not resolve host`, `Repository not found`, `not found`), then the last.

## FORMATS.md

- Unlocking: the encoded form. The providers' JSON. `encoding: base64`. `rejected`, `not loaded`.
- The broker's contract: `farmy-keys loaded`; a load the agent refuses answers an error.
- `.env`: `FARMY_UNLOCK_COMMAND`. The clone marker's lines and the reason farmy names.
- The fakes: `farmy-keys loaded` in a container prints the names of the last load since it started.

## Tests altered

None; the unlock kit reads the encoded form as the value it carries.

## Scenario list

keys_test.rb
- a multi-line SSH key from the unlock command reaches the broker's agent byte for byte, through the shim, farmy and the load
- a route with encoding: base64 has its secret decoded before the broker is loaded
- an SSH route whose secret is a base64-encoded key, without encoding: base64, is not loaded and farmy keys says it looks base64-encoded
- farmy keys reads the brokers: after the keys container restarts, a route reads not loaded
- restart loads the secrets into the keys container it made anew

providers_test.rb
- providers/env answers a multi-line secret as valid JSON, byte for byte
- providers/infisical answers a multi-line secret as valid JSON, byte for byte

broker_test.rb
- farmy-keys loaded lists the secrets the broker holds
- a base64-encoded key for an SSH route is refused with an error that says it looks base64-encoded

unlock_test.rb
- FARMY_UNLOCK_COMMAND in .env is used when the environment has none

start_test.rb
- a failed SSH clone names ssh's authentication line, not only git's last lines
