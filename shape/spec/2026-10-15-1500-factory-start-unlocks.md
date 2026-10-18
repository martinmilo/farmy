# 2026-10-15 15:00 — Factory start unlocks like every other command; show says (no output)

The owner's first green factory run on a machine: the run branch cut from main, the agent's commit, the gate
passing on that commit, the branch pushed over the SSH route through the mesh, main untouched.

Two things were wrong on the way.

1. Right after the control container was made anew (its holder empty), `farmy factory start` prompted on the
   terminal for the SSH route's secret instead of reading it from the Keychain under the prefix in `.env`.
   `farmy keys reload` read it without a prompt, and `factory start` then ran without one (the holder had it).
2. `factory show` printed `the last test output (iteration 1):` with nothing after it, for a passing gate that
   printed nothing.

## Decided

1. **One way to the values.** Every command that loads a broker or runs the provider (`start`, `restart`,
   `rebuild`, `keys reload`, `keys --why`, and `factory start`, which loads the run's broker and the service's
   for the git container) obtains the unlocking values the same way in the shim: the names the holder lacks
   (`farmy unlock-names --missing`), each from the one source (the unlock command, else the Keychain, else the
   secret service, with the prefix from the environment, else `.env`, else `farmy/`), a prompt only for a name
   the source does not have.
2. **`(no output)`.** `factory show` prints `(no output)` under the last test output heading when the gate
   printed nothing.

## Tests altered

None. The table in unlock_test.rb covers the five commands that already unlocked, so that none of them leaves
the common way again.

## Scenario list

unlock_test.rb (one row per command)
- farmy start / restart / rebuild / keys reload / keys --why / factory start with nothing held reads the Keychain under the prefix from .env and asks for nothing

factory_test.rb
- show says (no output) under the last test output of a gate that passed printing nothing
