# The broker's SSH agent ends with the broker

The suite's new process check (every test fails when it leaves processes running) found
`ssh-agent -a <scratch>/agent.sock` left behind by tests that stop the keys broker with TERM.
The broker runs that agent for `auth: ssh` routes; when the broker ends, the agent stayed. In
the sandbox that piled up 253 agents. A broker restart in production would leak them the same way.

## Decided (the owner, 2026-10-16)

The broker stops its own SSH agent when it ends: on TERM, on INT, and when the process that
started it goes away. This is a program fix by the worker; the tests say that no process the
broker started survives it.

## Scenarios

- A broker stopped with TERM ends its SSH agent with it.
- A broker stopped with INT ends its SSH agent with it.
- A broker whose parent goes away (killed with KILL) ends, and its SSH agent with it.

Each test first loads a key and sees it listed by `ssh-add -l`, so the agent was running.

## Open

The FactoryParallelTest database-gate failures seen in the same run are not part of this record.
