# 2026-10-13 06:00 — Secrets: an external source, a broker that is loaded, not configured

A review of the keys proposal in `2026-10-13-0400-control-container-and-session.md` (brought by the owner) approved the external-source direction and sent the proposal
back on four points: a value in a container's environment is in its Docker configuration, so
"memory only" was false; a command provider needs a protocol, not "run it and import what it
prints"; provider configuration is privileged and belongs to the operator; and the test kit must
follow the contract rather than limit it. This record adopts those corrections and settles the
open part of the 04:00 record.

## What was decided

- **Where secrets live is not farmy's business; obtaining them is.** A **provider** is an
  executable the operator names in `farmy.yml` (`secrets.provider`: the program and its
  arguments, run as given, no shell). farmy sends it a JSON request on stdin, naming the secrets
  it needs and nothing else; the provider answers JSON on stdout: the values it found, the names
  it did not, or an error. Stdout is secret-bearing data and is never shown or logged; stderr is
  the provider's channel to the operator and is shown. A provider that exits non-zero, answers
  something that is not the protocol, takes longer than 30 seconds or prints more than 1 MB is
  a failure that names the provider, never its output. farmy ships one provider as an example and
  the protocol in `FORMATS.md`, so that Infisical, 1Password, `pass`, a script or a native
  implementation can sit behind the same interface. The first release ships `farmy-provider-env`
  (reads the secrets from its own environment, for a laptop without a secrets manager) and the
  documented way to wrap `infisical`.
- **Unlocking.** A provider may need a secret of its own (an Infisical token). farmy passes the
  unlocking values to the provider process in its environment, under the names `farmy.yml`
  lists (`secrets.unlock: [INFISICAL_TOKEN]`), and nowhere else. Those values reach farmy on
  its standard input, as `NAME=value` lines, from the shim: on macOS the shim reads each from
  the Keychain (`security find-generic-password -s farmy -a NAME -w`); elsewhere, or when a
  name is not in the Keychain, farmy asks for it with a hidden prompt when it has a terminal.
  farmy holds them for the command and forgets them.
- **The broker starts empty and is loaded.** The keys helper (the broker, `<name>-keys`) is
  started with its routes in its environment and no secret. farmy loads the secrets into the
  running broker with `docker exec -i <name>-keys farmy-keys load`, the values on that process's
  stdin as JSON, and the loading command hands them to the broker over a Unix socket inside the
  container that no other container can reach. The port the app containers use (9181) has no
  endpoint that loads or changes anything. The broker keeps the values in its process memory.
- **The guarantee, as stated:** farmy does not put a secret, unlocking or upstream, into a
  container's configuration (`environment`, `-e`, labels), into a generated file, into a docker
  command line, into its own state under `.work/`, or into its output and logs. It is not a
  guarantee against the Docker daemon's administrator, who is the operator.
- **Lifecycle.** `start` and `restart` resolve the secrets and load the broker. A broker that
  is stopped and started again (`stop`, then `start`) is loaded again by that `start`. `farmy
  keys reload <name>` resolves and loads again without touching the containers. Attaching to the
  session, from this or another device, needs no secret: the brokers are running. A route whose
  secret the provider did not return is off, and `keys` says why: `missing` (the provider has no
  such secret), `locked` (an unlocking value was not given), `provider failed`. A failing source
  blocks only what needs the secret: the containers still start, the app still runs.
- **Routes and grants.** `keys.<route>` in `farmy.yml` names the upstream, the auth style, the
  secret's name at the source, the variable the app gets, and `services:` (the services that
  may use it; absent: all). The broker of a service gets only the routes granted to it, and only
  their secrets. A route forwards to its configured upstream only; the caller chooses the path,
  never the destination. `farmy.yml` and the service definitions are operator-owned: they live
  in the containers folder on the host, which no app container and no agent can write.
- **No catalogue** stays decided: farmy ships `farmy.example.yml` with the forge, Anthropic and
  OpenAI routes written out, inert until copied.
- **Tests follow the contract.** The acceptance suite stands in for the provider with a fake
  executable that speaks the protocol, observes delivery through the fake docker (which records
  what an `exec -i` received on stdin, so that a test can assert the secret went there and
  nowhere else), and tests the broker itself as a program: the suite starts `bin/farmy-keys`
  against a fake upstream of its own and checks what the upstream received and what the client
  did not. A small integration file, skipped unless a real Docker answers, covers what a fake
  cannot: that a loaded secret is absent from the daemon's configuration of the broker, that an
  Alpine base image builds, and that the session can be started, detached and reattached. It is
  run by hand on the host.

## Left out

- A native Infisical provider in Rust: possible later behind the same interface.
- A long-lived unlocking agent in the control container (an ssh-agent for the bootstrap
  secret): v1 asks per command, or reads the Keychain; revisit if the prompt gets in the way.
- Refreshing secrets on a schedule; expiry handling beyond "reload".

## Scenario list

keys_test.rb (the acceptance suite, fake provider, fake docker)
- the secrets a route needs are asked from the provider by name and nothing else is asked
- a secret the provider returns reaches the broker on stdin and no container's environment
- no secret value appears in a docker command line, a generated file, farmy's state or its output
- the app container gets the variable a route exposes, pointing at the route
- a route granted to some services is in those brokers only
- a route whose secret the provider does not have is off and keys says missing
- a provider that fails switches its routes off, says so without its output, and start goes on
- an unlocking value given on stdin reaches the provider's environment and nowhere else
- an unlocking value not given leaves the routes locked and keys says locked
- keys reload resolves and loads again without touching the containers
- a definition that names a route it is not granted is refused

broker_test.rb (bin/farmy-keys as a program, a fake upstream in the test)
- a request through a route reaches the upstream with the secret in the auth header
- the client's own authorization header does not reach the upstream
- a route that was never loaded answers 503 and names the route
- a path outside the configured routes answers 404
- a redirect from the upstream is rewritten to stay on the route
- the loading socket is not reachable through the proxy port

integration_test.rb (skipped unless a real Docker answers; run by hand on the host)
- a secret loaded into the broker is not in its Docker configuration
- the toolbox builds on an Alpine base image
- the session starts, detaches and reattaches

Test fixes from the review
- assert_ran_in checks user and folder on the same execution.
- the volumes-and-networks test asserts a network.
- the Alpine test is renamed to what it shows ("an Alpine image is accepted by farmy").
