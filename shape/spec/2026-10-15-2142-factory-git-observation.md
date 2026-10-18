# Factory assertions observe factory runs

The shared Git-container launcher introduces service-clone helpers alongside factory Git
helpers. Both may have `farmy.role=git`. The factory test observation previously selected
that role without checking membership of a factory run, so it also selected service helpers
started before the test configured SSH routes or mesh egress.

The related suite demonstrated this in two tests: "the git container is the only run
container with the agent socket" and "the git container gets the proxy variables and an
ssh ProxyCommand through the mesh". Both failed on the earlier service-clone helper; the
factory command itself completed green. The agreed behavior has not changed.

Factory-scoped observations now require the existing nonempty `farmy.run` label as well
as the requested role. They continue to check every matching factory helper, and still
require factory Git to have its configured socket/proxy settings while agents and gates
remain isolated. The common Git-container test remains independent of this factory-only
scope and checks service cloning, Dockerfile fetching and dotfiles operations too.

## Scenario

1. The existing two factory transport tests check helpers belonging to factory runs even
   when the service was first started before SSH or mesh was configured; the shared-launcher
   test continues to check all Git helpers under its configured SSH-through-mesh route.

This corrects the observation affected by the owner's accepted shared-launcher change;
it does not add a product decision or relax any credential or routing requirement.
