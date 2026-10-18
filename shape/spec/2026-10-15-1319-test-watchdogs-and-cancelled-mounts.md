# Test watchdogs and cancelled fake mounts

The broad pipeline run at eight parallel test processes reached the harness's 12-second
observation deadlines and 20-second command watchdog while public status still showed progress.
The full pipeline milestone had passed when run alone. No approved scenario defines those wall
clock limits as product behavior. Keep bounded waits, using 45 seconds for pipeline observations
and 60 seconds for a command, with the existing short polling interval. Fake agent barriers allow
90 seconds so the test can inspect state and release them. Configured gate health, iteration and
notification timeouts keep their existing requirements.

Cancellation can kill a fake Docker process before its ensure block restores permissions used to
simulate a read-only mount. Subsequent fixture removal then fails on a Git hooks directory even
after the product assertions have completed. Teardown now restores owner access to directories
inside that test's scratch tree, without following symlinks, before deleting it. Read-only checks
and run-resource cleanup assertions still occur before this teardown-only operation.

These are harness corrections for the existing concurrent and cancellation scenarios. They do
not change verdicts, resource-ownership expectations, or the requirement that an app cannot write
the shared dotfiles clone.
