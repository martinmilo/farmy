# An orphan that cannot be removed blocks the turn

The login turn record (2026-10-19-0907) has a run remove orphaned agent containers of its factory login
before its own agent starts. When `docker rm -f` failed, the worker's choice was to warn and start the agent
anyway: two agents on one login, the race the turn exists to prevent.

Decided (the owner, 2026-10-19), before 0.1.1:

- A failing removal is tried again: at least 3 tries, spread over about 10 s.
- When the orphan still cannot be removed, the run does not start its agent. It ends with the result
  `login_blocked`; `factory show` names the container and Docker's error. Never two agents on one login.
- A removal that works on a later try goes on as before (recorded in `orphans_stopped`).

The fake docker can fail `docker rm` of a container a given number of times, or always, with Docker's
words for a container it cannot kill ("could not kill: permission denied").

## Scenarios (FactoryLoginOrphansTest)

1. An orphan that cannot be removed is tried again over about 10 s, then the run refuses to start its agent,
   naming the container and Docker's error.
2. An orphan whose removal fails at first and then works is removed, and the run goes on.
