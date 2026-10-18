# Pipeline questions from the answering profile and useful failure reports

The owner observed a pipeline's first shape step asking a question, which was incorrectly
sent to another shape run through on_question. That answering run edited forbidden paths
and stopped, while neither the diagnostics nor the printed follow-up command helped review it.
These corrections extend the active Mini regression work and supersede only the affected
question routing and diagnostic behavior.

Compare the questioning child's profile with the pipeline's on_question profile, regardless
of whether the child is a normal step or an answering handoff. When they are equal, pause
in question for a human factory answer. Do not dispatch another agent or spend a handoff.
An answer resumes that step under the same profile and existing review/gate rules. Questions
from other profiles continue to use the configured answering profile.

A permission_violation records the actual changed paths before restoring or dropping them.
Run show, pipeline show and every configured notification format name those paths and state
that the changes were dropped. Include paths outside writes and those under protects/hidden.
Do not include file contents, task text, questions, answers or logs in a notification merely
to explain the violation. Retain the existing no-continuation/no-push outcome and prove the
reported edits really are absent from the resulting commit.

A command printed when a pipeline pauses or ends must accept that pipeline ID. Prefer
`farmy factory pipeline show <id>`; accepting both ID kinds in factory show also satisfies
the owner's request. Test the printed command by executing it, rather than only its spelling.

## Regression scenarios

1. A first shape step whose profile is also on_question pauses in question with one agent
   invocation and zero handoffs instead of dispatching a second shaper.
2. The same routing rule works when the profile has another name.
3. A human factory answer resumes that original shape step, puts the answer in its prompt,
   and waits for review of its test change before starting the worker.
4. Run show names the outside-writes, protected and hidden paths and says their edits were dropped.
5. Pipeline show carries the same actual path list and dropped outcome.
6. JSON, ntfy and Slack-compatible failure notifications name the dropped paths without file contents.
7. A pipeline's printed follow-up command succeeds for review, question, green and failed outcomes.

The existing answering-shaper-asks-a-question and other-profile-dispatch tests remain in force.
The shaper adds these regressions before the worker changes the pipeline behavior.
