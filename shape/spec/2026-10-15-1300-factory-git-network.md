# 2026-10-15 13:00 — Factory: git on the farmy network, names the picker knows, destroy removes every volume

The owner's second factory run on a machine. Ownership held; the run's git container failed at the fetch:

    nc: getaddrinfo for host "farmy-egress" port 1055: Name or service not known
    kex_exchange_identification: Connection closed by remote host
    fatal: Could not read from remote repository.

The git container had the proxy variables and the ProxyCommand (11:00) but was only on the service's
network, where `farmy-egress` does not resolve. The fake resolved every name everywhere, so the suite was
green. And `farmy destroy` left `<name>-src`: compose's `down -v` skips a volume it did not create, and an
earlier farmy had created it.

## Decided

1. **Every factory git container is on the service's network and on `farmy`**, where `farmy-egress` (and an
   `egress: {proxy: …}` name the host's DNS knows) resolves. Since `docker run` takes one network on older
   Docker engines, a git container is made with `docker create` on the service's network, joined to `farmy`
   with `docker network connect`, and run with `docker start -a` (it is `--rm`). The agent's container and
   the gate stay off `farmy`.
2. **The cause picker** (FORMATS, the clone marker) gains `getaddrinfo`, `Name or service not known` and
   `Could not resolve hostname` (`Connection refused` is there already).
3. **`farmy destroy` removes the service's farmy-named volumes itself**, whoever made them: `<name>-src`,
   `<name>-agents`, `<name>-keys-agent`, `<name>-<mount>` for each of the definition's `mounts:`, and the
   service's run volumes `<name>-run-*`, after compose's `down -v` (which keeps removing what it made, the
   fragment's own volumes).

## The fake

A container resolves only the names on the networks it is attached to: container names, compose service
names and aliases (`--network-alias`, `docker network connect --alias`); the default bridge and `none` resolve
nothing; a name with a dot is the host's DNS and resolves. A `farmy.role=git` container that fetches, pushes
or pulls with a proxy, a ProxyCommand host or a broker route in its environment that it cannot resolve fails
as git does (`nc: getaddrinfo for host "<name>" port <port>: Name or service not known` and ssh's and git's
lines; for a broker route `Could not resolve host: <name>`), exit 128. `docker create` of a factory container
records it, `docker network connect` attaches it, `docker start -a` runs it then. Compose's `down -v` removes
only volumes with its project's label, as the real one.

## Tests altered

`factory_test.rb`, "the git container gets the proxy variables and an ssh ProxyCommand through the mesh":
it now also asserts the run succeeds (it passed on a refused run before, reading the refused container's
environment).

## Scenario list

factory_test.rb
- every git container of a run is on the service's network and on farmy, where the egress node resolves; the agent's and the gate's are not on farmy
- destroy removes the service's run volumes

start_test.rb
- a clone that fails on a name it cannot resolve names getaddrinfo's line

stop_and_destroy_test.rb
- destroy removes the checkout volume even when an earlier farmy, not compose, made it
