# Complete valid release and escaping-link fixtures

The new publishing fixtures must satisfy every unrelated release requirement. Give each
new private/public release its versioned public notes file, so a lineage or retry scenario
does not also describe missing release notes. No assertion changes.

The escaping-link fixture must resolve to an existing file outside the export. The earlier
relative target also did not exist, so an implementation checking only dangling links could
pass it. Create a unique external file and link to it; retain the same refusal and unchanged
refs assertions. Keep the separate dangling and excluded-target cases.
