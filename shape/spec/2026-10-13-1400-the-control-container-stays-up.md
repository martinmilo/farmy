# 2026-10-13 14:00 — The control container stays up

The first real run, step 1 (`farmy init` on a Mac with Docker only): the control image builds,
the control container starts and crash-loops, `docker logs farmy` repeating

    farmy: unknown command 'tail' — farmy help lists the commands

The image's entrypoint is the farmy binary and the shim starts the container with
`tail -f /dev/null`, which farmy reads as a subcommand. The two halves were written against each
other and never run together: the shim and the control image were outside the suite.

A second thing came out while writing the test: the control container and the shared knowledge
container are both named `farmy`. The tests run the binary directly, so the control container
never existed next to the knowledge container; on a real machine step 2 would have failed on
the name.

## Decided

- **The control container's main process is never the farmy binary.** farmy is a command-line
  tool and exits; the container exists so that `docker exec` has somewhere to run it. Whatever the
  shim starts it with, and whatever the image's entrypoint is, the resulting process keeps the
  container up. The fake docker now composes a container's process from the image's `ENTRYPOINT`
  and `CMD` and the `docker run` line, as Docker does, so this is checked without a daemon.
- **The shim runs under the suite** for that seam: `farmy init` through the shim, with the fake
  docker, leaves a running control container `farmy` whose process is not farmy. The integration
  tests check the same against the real Docker. The TUI stays outside.
- **The knowledge container is `farmy-knowledge`**, on the network `farmy`, at
  `http://farmy-knowledge:9190/mcp`. The control container keeps the name `farmy`.

## Not decided here

- What the control container's process is (a sleeper, tmux, anything). Only that it is not farmy.

## FORMATS.md

- "How farmy runs": the control container is `farmy`, stays up, its process is not farmy; what
  is and is not under the suite.
- The knowledge container's name and address; the Names table.
- The fake docker: `ENTRYPOINT`/`CMD` and the process of a container.

## Tests

- `test/support/farmy.rb`: `refute_process name, program`.
- New `shim_test.rb`; `integration_test.rb`; the knowledge container renamed in `start_test.rb`,
  `stop_and_destroy_test.rb`, `toolbox_test.rb`.

## Scenario list

shim_test.rb
- init through the shim leaves the control container up, with a process that is not the farmy binary

integration_test.rb
- farmy init leaves the control container running

start_test.rb / stop_and_destroy_test.rb / toolbox_test.rb
- the shared knowledge container is farmy-knowledge (renamed in three existing tests)
