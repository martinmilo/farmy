# Observe equivalent GitHub matrix layouts correctly

The workflow checks must accept both a Cartesian matrix and an explicit include list of
native build rows. Their matrix reader initially merged pure include rows into one row,
which is not GitHub's expansion rule. Keep pure include entries separate, merge additions
only into original Cartesian rows, and support nested matrix field references. No expected
platform, runner, image, permission, digest or dependency changes.
