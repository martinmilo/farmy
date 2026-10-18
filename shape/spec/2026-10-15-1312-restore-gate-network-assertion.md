# Restore the gate's internal-network assertion

The approved pipeline sidecar scenarios PS30–PS33 preserve the factory gate's existing network
isolation while replacing shared developer sidecars with fresh run-owned copies. The previous
`FactoryTest` sidecar-reachability assertion checked that the gate network was internal. Its new
`assert_gate_sidecar_copy` helper checked network separation and sidecar reachability but omitted
that flag, allowing an outward-facing Compose network to satisfy the test.

Restore that invariant in the existing helper: every network attached to the gate or its sidecar
copy must have `internal: true`, as observed in the retained generated Compose definition or Docker
network-create history. These observations remain available after gate cleanup. Generated Compose
references to a separately created network use the latter evidence; an external reference alone is
not proof of isolation.

This restores the original isolation assertion within already-approved scenarios. It adds no new
scenario, product requirement, or implementation dependency. The worker remains separate; this
correction does not inspect its source or run a build while implementation is active.
