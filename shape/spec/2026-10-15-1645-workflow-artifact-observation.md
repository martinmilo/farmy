# Observe workflow inputs without fixing the generator command

The first implementation run exposed two observation errors in PublishingWorkflowTest.
The workflow may bind a build digest through a job or step environment variable; observing
only run/with omitted that valid handoff. Include those environment values in the structural
view. The release asset requirement names install and SHA256SUMS, not a command that must
generate them. Check the actual release attachment inputs instead of requiring a literal
bin/install path in the workflow. Retain checksum, dependency, permissions, tag, digest and
release-notes checks. Generation may use a shared renderer for build-time configuration.

PublishingDefaultsTest's policy assertions also normalize whitespace so ordinary Markdown
line wrapping does not change whether a sentence explains maintainer application and credit.
No accepted behavior or scenario changes; these repairs make the observations match it.
