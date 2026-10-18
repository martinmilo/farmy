# Observe the deepest matching volume mount

The full regression run exposed a fake-Docker boundary error in the existing hook-status scenario.
An app now has a persistent volume at /home/dev as well as the existing nested agent-state volume.
The fake's `cat` response selected the first matching mount, so a valid parent-first mount list hid
the nested file from the test. A separate fake-only reproduction with a populated nested volume
returned a false missing-file error without running the worker's program.

Docker resolves a path through the deepest applicable mount. The fake must select the longest
matching target, independent of list order, and resolve a mounted subpath within that volume.
The existing StatusJsonTest hook-status case keeps its expectation: the hook's state and timestamp
are visible through public status. No product mount-order requirement or status behavior changes.

Apply the boundary correction after the active full run, check the synthetic parent-first and
child-first cases, then rerun the affected status/mount acceptance checks. The shaper does not
inspect the implementation to make this correction.
