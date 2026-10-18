# 2026-10-13 07:00 — An SSH route: the broker as an SSH agent

The owner, on the forge route of the example file: "What if there is no token but an SSH
key?" and, offered a token over HTTPS first: "No, I already have SSH set up for this, I don't want
to switch." So the forge route must work with an SSH key, under the same rule as every other secret:
the app container never holds it.

## What was decided

- **A route may be `auth: ssh`.** Its secret is the private key (the text of an OpenSSH private key,
  from the provider like any secret); it has no upstream. The broker runs an **SSH agent** holding
  that key and offers the agent's socket to the app container on a shared volume
  (`<name>-keys-agent`, at `/run/farmy-keys`); the app container gets
  `SSH_AUTH_SOCK=/run/farmy-keys/agent.sock`. Its git and ssh sign with the key through the agent and
  never read it. The key is loaded into the broker the same way as the others (`farmy-keys load`,
  stdin, the socket inside the container), and the broker hands it to the agent on stdin.
- **With an SSH forge route the repositories are cloned over SSH:** `repo: acme/hub` becomes
  `ssh://git@<forge host>/acme/hub.git` (`FORGE_SSH_USER` in `.env` changes the user; a full
  `ssh://` or `git@host:path` URL in `repo:` is taken as it is). farmy's own fetch of a Dockerfile
  uses an agent of its own in the control container, fed the same way, for the duration of the
  clone. The forge's host key is accepted at first contact (`StrictHostKeyChecking=accept-new`).
- The HTTPS route stays as it is; a containers folder uses one or the other for the forge.

## Scenario list

keys_test.rb
- an SSH forge route gives the app container an agent socket and never the key
- with an SSH forge route the repository is cloned over SSH

broker_test.rb
- a key loaded for an SSH route is served by the broker's agent
