# A worker's question: the root-made container test counted its own setup

The worker built records 2026-10-29-1800 and 2026-10-29-1931 and stopped on one failing test, with a question:

> HostUserTest "a control container made to run farmy as root for a root caller is not used for a plain user's
> commands: with no live run it is made anew for that user" wants every `docker exec` of farmy to run as the
> invoking user; the one it lists is the setup's own `farmy init`, which the setup says root ran as root. The
> command under test runs as the user.

The worker is right, and the test was wrong. Its setup makes the control container by running `farmy init` as root
(that is the situation), and `assert_farmy_ran_as_the_invoking_user` counted every farmy exec of the test, the
setup's included. Nothing was decided differently.

## Changed

- The kit's `farmy_execs` counts, after a setup that runs farmy itself
  (`control_container_made_for_root_by_a_root_caller`), only what the shim handed over after that setup. That
  covers `assert_farmy_ran_as_the_invoking_user` and `assert_farmy_ran_as_root`.
- The test keeps its name and its meaning: the command a plain user runs there runs as that user, in a container
  made anew.
