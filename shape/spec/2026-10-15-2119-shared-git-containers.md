# One launcher for farmy's Git operations

The owner reports that a dotfiles repository named with an HTTPS URL cannot be cloned
through its SSH Git route and mesh egress: SSH tries to resolve the upstream directly.
Another independently assembled Git container has missed the standard connection setup.
The owner requests one function that starts all containers farmy uses for its own Git
operations: service clone, factory Git, Dockerfile/build-file fetch, and dotfiles clone/pull.
This is an explicit implementation requirement, not only a request to patch dotfiles flags.

Every such container receives the applicable service network plus farmy network, all
configured proxy variables and local bypasses, a proxy-aware SSH command, the loaded
route broker's agent socket, and token/SSH URL rewrites. An HTTPS repository URL must keep
working through an SSH route for clone and later fetch/pull/push. Private keys remain in
the broker. The launcher centralizes this setup; callers supply their operation, image,
mounts, identity and lifecycle requirements. App Git preferences remain user-owned, and
agent/gate isolation remains as already specified.

## Accepted scenario

1. One acceptance test exercises service clone, factory Git, Dockerfile fetch and dotfiles
   clone/pull, then applies one common plumbing assertion to every Git container observed;
   a private HTTPS dotfiles repository reachable only through an SSH route and mesh proxy
   refuses incomplete plumbing in the fake and successfully clones and updates once the
   full setup is present.

The owner supplied this scenario explicitly; no further behavior decision or approval is
needed. The fake must check routing before translating the fake remote to a local bare
repository. Merely observing the agent socket or substituting a local URL is insufficient.
The test must demonstrate every named entry point was exercised, not pass over an empty
set of helper containers. A source audit by the worker establishes the single-launcher
requirement, while the test protects its externally visible configuration and behavior.

The earlier ruby-psych recipe corrections remain uncommitted pending real image builds.
This task preserves those changes and the build-before-commit requirement. Fake Docker
tests here make no claim that an image was built on a real runtime.

The existing StartTest clone-failure case is renamed from entrypoint-specific wording to
service-clone wording, with all outcomes unchanged: exit 1, the actual cause and an app
available for inspection. Its fake remote failure now applies at either launch boundary.
Existing illustrative internet repositories remain simulated; local fixtures run real Git.

The initial new test fails at dotfiles clone, naming the absent farmy network, all proxy
settings, SSH ProxyCommand and HTTPS-to-SSH insteadOf rule. Existing dotfiles/build-fetch
checks pass (33 cases, 301 assertions) before the implementation handoff.
