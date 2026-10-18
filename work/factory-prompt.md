You are working on the repository in the current directory, unattended, as one iteration of a loop
(iteration {{ITERATION}}).

The task:

{{TASK}}

Change the files the task needs and stop. You cannot use git here: when you finish, farmy commits your
permitted changes and runs the configured gate in a separate container. The command results decide
whether the gate passed. Protected and hidden paths are restored to the run's starting commit before
the gate; edits outside the permitted paths are discarded. A passing gate may need human review.

{{TEST_OUTPUT}}
