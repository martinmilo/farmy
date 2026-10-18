# Answer revision reference

The approved pipeline contract distinguishes a revision's starting commit from the commit against
which its red_first gate must fail. An initial answering shaper starts from the worker's captured
question commit. A revision starts from the prior answering attempt on the same branch, while its
red_reference_commit remains the worker's question commit.

The PipelinesTest scenario "revising an answering shaper's test change still withholds it from the
worker until approval" now asserts the fixed red reference without incorrectly requiring that
revision's source_commit to equal the question commit. The initial-answer scenario still requires
both source_commit and red_reference_commit to equal the question commit. Both retain the worker's
captured edits and human review requirement. This corrects the new test to the already-approved
revision behavior; it adds no scenario or product decision.
