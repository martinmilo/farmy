# 2026-10-15 14:00 — Factory: the agent's way out, cleanup of what was made, the agent's cause

The owner's third factory run on a machine: the run cloned and branched; the agent died at once with
`API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)`, and cleanup printed
`No such container: <name>-run-<id>-keys` and `network <name>-run-<id> not found`.

What it was: in token mode the agent ran on Docker's default bridge carrying the egress proxy variables
(`HTTPS_PROXY=http://farmy-egress:1055`), and `farmy-egress` does not resolve there. In api-key mode the run's
broker had the same variables on a network where the proxy does not resolve. The fake knew no way out, so
the suite was green.

## Decided

1. **The agent's way out.**
   - **Token mode** (and a subscription login): the agent runs on a network of the run's own with internet
     access, `<name>-run-<id>-out` (made without `--internal`), never `farmy` and never the service's
     network, and gets **no proxy variables** (it cannot resolve the proxy there, and its model is public).
   - **Api-key mode**: the agent runs on the run's internal network `<name>-run-<id>` (`docker network
     create --internal`), where only its broker is. The broker gets the way out: it is joined to
     `<name>-run-<id>-out`, and with `egress:` to `farmy` as well, where its proxy resolves (the broker keeps
     the proxy variables; the agent gets none).
   - **For the egress-control record**, noted, not built: restricting the agent's way out to its model's API
     host (an allowlist on the run's outbound network, or the agent always behind its broker).
2. **Cleanup removes only what the run made**: the broker and the networks it created, in either mode; no
   line about a container or a network that is not there, at the end of a run or at cancel.
3. **`show` names the agent's cause** next to `agent_failed`: the first line of the agent's log that names a
   cause (`API Error`, `Error:`, `error:`, `ENOTFOUND`, `ECONNREFUSED`, `401`, `403`, `rate limit`), else its
   last line: `result     agent_failed — API Error: Can't reach the API server — check your internet or DNS
   (ENOTFOUND)`.

## The fake

A network made with `--internal`, and `none`, have no way out; one made without it, and Docker's bridge, do.
An agent container reaches its model through its broker (a variable pointing at `http://keys:9181/…`: `keys`
must resolve on its networks, and the broker must reach out), else straight out: through the proxy its
environment names (which must resolve on its networks, or be a DNS name on a network with a way out), else on
a network with a way out. When it cannot, the agent prints `API Error: Can't reach the API server — check your
internet or DNS (ENOTFOUND)`, writes nothing and exits 1. `docker rm -f` of a container and `docker network rm`
of a network that do not exist fail as Docker does, on stderr.

## Tests altered

The kit's `refute_sidecar_joins` looks at the gate's network only (the run's broker now joins its outbound network,
which is no sidecar join). Otherwise none; "the git container gets the proxy variables and an ssh ProxyCommand through the mesh" now passes only
with the broker's way out fixed (its run is in api-key mode with mesh egress).

## Scenario list

factory_test.rb
- an agent in token mode reaches its model on an outbound network of the run, never farmy or the service's network, and carries no proxy variables
- in api-key mode the agent is on the run's internal network with only its broker, and the broker has the way out
- a run in token mode removes only what it made: no line about a container or network that is not there
- a run in api mode removes only what it made: no line about a container or network that is not there
- show names the first cause line of the agent's log next to agent_failed
