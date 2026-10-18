# Null assertion reporting

The worker's suite output showed successful notification and publication-related checks
reported as errors because Minitest's deprecated `assert_equal nil` form emits a warning
before the progress marker. This is a test-harness issue, not a product behavior change.

The shaper replaces expected-null comparisons with `assert_nil` in the notification payload
and public run-status helpers. Non-null values still use `assert_equal`; expected values,
key-presence checks and failure messages remain unchanged. No scenario is added or weakened,
and the test runner's output parser is unchanged.

Validation for this edit is Ruby syntax and whitespace checking. The coordinating agent
will run the suite after the paused worker and other shaper repairs are ready.
