# Two follow-ups after 0.1.0, from the lint sweep

Both were kept as they are in the sweep (their #[expect] reasons say so); the owner decided
(2026-10-17) to fix them after 0.1.0, each in a record of its own with tests.

## A state.json that cannot be written is never lost silently

factory.rs (save, ~:178/:182), factory_pipelines.rs (save_pipeline, ~:30/:33) and filter.rs (~:179/:183)
write a temporary file and rename it over state.json, and ignore a failed write or rename. A full disk or
a read-only folder then loses a state transition without a word, and status shows an old state. The
follow-up: a failed state write is reported (the command fails, or the controller ends its run as
failed, naming the file and the error), never ignored; what each caller does is decided in that record.

## The broker never forwards a partial request body

farmy-keys (main.rs ~:640) forwards a request body that fails while being read as far as it arrived, so
the upstream receives a truncated request with the route's credentials. The follow-up: the broker aborts
the upstream request when the client's body cannot be read in full, and answers the client with an
error. A truncated streamed response from the upstream (main.rs ~:702) is fine as it is: it reaches the
client as far as it came.
