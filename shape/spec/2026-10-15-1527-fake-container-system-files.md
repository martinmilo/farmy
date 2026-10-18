# Isolate system files for every fake app execution

The linked-personal-Git-config regressions now reach a legitimate root execution after
the dev dotfiles installer: refreshing managed system Git defaults. The fake mapped
container system directories only during the explicit full-entrypoint probe, so this
earlier execution tried to write the test host's /etc/gitconfig and failed with a
permission error. A real root Docker execution writes the container's filesystem.

Map /etc, /run, /var/log and /var/lib into each fake container's own filesystem for
every toolbox execution, preserving explicit mounts. Give real Git that isolated
system configuration and the container's personal configuration instead of the test
host's Git settings. Leave process/daemon stubs scoped to the full-entrypoint probe.
Preserve nil environment entries when mapping a fake remote; they deliberately unset
host variables for the child process.

This corrects the fake OS boundary; no product requirement or assertion changes.
Recheck PersonalGitConfigTest, PipelineMiniRegressionsTest and the existing dotfiles
and shared-data behaviours before returning the worker to implementation.
