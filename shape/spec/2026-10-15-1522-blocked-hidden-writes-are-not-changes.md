# Do not report a blocked hidden write as an actual dropped change

The permission-report regressions scripted writes to an outside-writes path, a protected
path and a hidden path, then expected all three in the report. The existing fake correctly
skips writes covered by tmpfs; hidden paths are mounted read-only. Inspection of that fake
boundary confirms that private/notes.txt was never changed. The worker's actual changed-path
observation therefore returned the other two paths, as it should.

Correct the fixture's expectations: report the actual outside-writes and protected edits as
dropped, retain all original file contents, and do not invent a dropped-path report for the
blocked hidden write. This is a correction to what the fixture did, not a weaker permission
rule. A real hidden-path change, if one is present in the checkout inspected after an agent,
must still be captured before cleanup, restored and included in the report. The worker adds
a unit regression against a temporary Git checkout with such an actual hidden-path change.

The affected tests are the run/pipeline show and JSON/ntfy/Slack permission-report cases in
PipelineMiniRegressionsTest. No routing, review, publication or privacy expectation changes.
