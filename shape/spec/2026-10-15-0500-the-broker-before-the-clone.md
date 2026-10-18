# 2026-10-15 05:00 — The broker before the clone

The owner ran record 2900: the chain works. With the key loaded, `ssh-add -l` in the app container
lists it through the broker's agent, and a clone of a private repository over SSH through the
egress proxy succeeds. `start` still did not get there by itself.

## Decided

1. **Load, then wait for the clone.** `start`, `restart` and `rebuild` loaded each broker only
   after the clone had been waited for, so the entrypoint cloned against an empty agent, and a
   keys container made anew was empty when the clone ran. Each broker is now loaded right after its
   service's containers are up, before the clone is waited for, in all three commands. `keys
   reload` stays for later changes.
2. **The reason names the cause.** Of the marker's lines farmy names the first that names a cause
   (`Error connecting to agent`, `Permission denied`, `Host key verification failed`, `Could not
   resolve host`, `Connection refused`, `Connection timed out`, `No route to host`, `SOCKS`,
   `Repository not found`, `not found`, `unable to access`), and no closing advice such as "Please
   make sure you have the correct access rights"; with none of them, the last two lines.
3. **The entrypoint retries a clone** that fails for a reason that may pass (a proxy that answered
   "General SOCKS server failure" right after a recreate, a connection refused): up to four tries
   over about thirty seconds before it writes `failed`. A refused key or a missing repository is
   not retried. Not testable through the fake docker; stated in FORMATS.

## FORMATS.md

- The order at start, restart and rebuild. The reason rule. The entrypoint's retries.
- The fake: an app container with `SSH_AUTH_SOCK` (an SSH route) clones only when its keys container
  was loaded since it last started; else its marker reads `failed` with `Permission denied (publickey)`.

## Tests altered

None.

## Scenario list

keys_test.rb
- start loads the broker before the clone, so a clone over an SSH route succeeds
- restart and rebuild make the keys container anew and load it before the clone

start_test.rb
- a failed clone names the first line that names the cause and none of git's closing advice
