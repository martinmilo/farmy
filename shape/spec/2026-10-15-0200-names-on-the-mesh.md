# 2026-10-15 02:00 — Names on the mesh

The owner ran record 2600. The node registered, both ends saw each other, TCP by IP worked through
both proxies. By name it failed, in the node's log:

    socks5: client connection failed: lookup git.example.com on 127.0.0.11:53: no such host
    http: proxy error: lookup secrets.example.com on 127.0.0.11:53: no such host

In userspace-networking mode the proxies resolve names with the container's system resolver, which
knows nothing of the tailnet's DNS (`tailscale dns query` on the node answers). Names outside the
tailnet suffix (extra records, split DNS) are what people put behind a mesh, so they must resolve.

## Decided

- **Kernel mode by default.** The egress container gets the device `/dev/net/tun` and the
  capability `NET_ADMIN`, `tailscaled` runs with a TUN interface, and the login passes
  `--accept-dns=true`, so tailscaled manages the container's resolver and the SOCKS5 and HTTP
  proxies resolve through it. The proxies stay the only way other containers use the node.
- **Fallback.** When the daemon refuses the device or the capability (compose up fails, or the
  node does not come up), farmy makes the node again in userspace mode and says, at start and in
  status, that only names under the tailnet's suffix resolve through the proxy. Status JSON gets
  `mode` (`kernel` | `userspace`) and `note` (that sentence in userspace mode, else null).
- **The Infisical provider passes the CLI's stderr through** (its own stderr): farmy still shows
  nothing of it while loading, `farmy keys --why` shows it redacted.
- **No stale clone marker.** Before the containers come up (made anew or started again), farmy
  removes `/workspace/.farmy-clone` from the checkout's volume, so start reads only the marker the
  new container's entrypoint writes.
- **The egress guide** gets the control-server side: a node registered by URL under a new user
  got no peers until it was moved to the user that owns the tag, and the control server had to be
  restarted to recompute peers; a pre-auth key created with `--tags` under the owning user avoids
  both. `tailscale ping` is not an ACL test (it answers below the ACLs).

## FORMATS.md

- Mesh egress: the device, the capability, `--accept-dns=true`, the fallback, `mode` and `note`.
- The clone marker removed before the containers come up.
- The fakes: `devices:`/`cap_add:` (and `--device`/`--cap-add`) kept on a container; a device the
  daemon refuses (`docker_refuses_device`); `rm -f <path>` in a container or a `docker run` removes
  a file from a volume mounted there; the entrypoint's clone result per container (`clone_fails`).

## Tests altered

- `egress_test.rb`, "status --json shows the egress node with its mesh name and address": the
  expected entry gains `mode: kernel` and `note: null`.
- `start_test.rb`, "a clone the entrypoint reports as failed ends start…": the failure is now the
  new container's (`clone_fails`), since a marker on the volume before start is a stale one.

## Scenario list

egress_test.rb
- a start with egress runs the node with the TUN device and NET_ADMIN, and its login accepts the tailnet's DNS
- when the daemon refuses the TUN device the node runs in userspace mode, and start and status say only tailnet names resolve

providers_test.rb
- keys --why with the Infisical provider shows the CLI's own error, redacted

start_test.rb
- a stale clone marker from an earlier attempt is removed before the containers come up, and start goes on

integration_test.rb
- the egress node runs in kernel mode with a tailscale0 interface
