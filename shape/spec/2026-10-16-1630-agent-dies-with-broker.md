# The SSH agent dies with a killed broker

Supersedes the open point of 2026-10-16-1530. The owner accepted the worker's choices for the
broker's shutdown (exit 0 on TERM, INT and a lost parent; an agent the broker did not start is
left alone; SIGHUP unchanged), except one: the broker's ssh-agent must also end when the
broker is killed with KILL, so it cannot clean up. The owner chose the kernel's parent-death
signal (SIGTERM) on the agent child for this.

## Scenarios

- A broker killed with KILL leaves no SSH agent running.
