# Observe workspace files while detached controllers update state

The full regression completed 707 cases with no assertion failures and one observation error.
The review_answers text-only approval scenario reached its status poll while a detached
controller atomically replaced a state file. Workspace#snapshot enumerated the temporary name,
then tried to hash it after the rename, raising Errno::ENOENT before the status command ran.
A fake-independent helper reproduction that renames a file between enumeration and hashing
produces the same exception.

Treat a path that disappears during hashing as absent from that snapshot. Do not exclude an
entire folder or temporary-file pattern, and do not suppress permission or other read errors.
Stable files keep their content hashes; a following snapshot observes the renamed destination.
This changes only the workspace observation helper, not the pipeline scenario or its assertions.
Check the race deterministically, check that other read errors still surface, and rerun the
affected pipeline scenario before the final regression. No product decision changes.
