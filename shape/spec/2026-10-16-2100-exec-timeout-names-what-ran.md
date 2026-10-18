# A timed-out step names the command that ran

Supersedes one scenario of 2026-10-16-2000. The timeout test hung the dotfiles installer and expected
`farmy-entrypoint` in the report. But the step that hangs there is the dotfiles/home step, which farmy
runs as `farmy-home.sh` (other dotfiles tests require that explicit form); `--git-config` runs only
after it succeeds. The test named a command that never ran. The worker raised it in QUESTIONS.md.

Decided: the requirement is "reported as timed out with its command", the command that actually ran.
The test now reads "a step in an app container that does not return within FARMY_EXEC_TIMEOUT seconds
is stopped and reported as timed out with the command it ran" and asserts
`[shop] … timed out after 3s: <command>`, without naming which command. Changed test:
EntrypointExecTest's timeout test (renamed; the `farmy-entrypoint` assertion removed).
