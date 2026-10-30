# The default home on a real host: what the fake docker could not show

Follows records 2026-10-29-0926 (a default home) and 2026-10-29-1030 (start without init). The worker built both;
the suite passes them. The suite drives the shim through a fake docker and runs the binary on the test machine,
so it cannot show what a real control container or a Mac does differently. A read-only helper reviewed the shim
and the binary for that *(helper)*. Its findings that change behaviour are decided here by the shaper; the owner
may overrule them.

## Decided

1. **A parent Git repository is found on the host.**
   - Problem: inside the control container only the folder and the state folder are mounted, so farmy cannot see
     the `.git` of a dotfiles `~/.config`. Set-up would ask the git question anyway, and `config git` (or a yes)
     would make a nested repository inside the dotfiles one.
   - The shim now finds the repository on the host: the nearest folder holding a `.git` (folder or file), the
     folder in use itself or a parent. It finds it by looking, without running git, and hands that top folder to
     farmy as `FARMY_HOST_GIT_TOP`.
   - farmy takes the variable, when set and not empty, as the repository the folder lies in. Without it, farmy
     asks git where it runs, as before; that is right when farmy runs on the host itself.
2. **No git on a Mac without the developer tools.**
   - Problem: since record 0926 the shim asks git for the identity on every command. On a Mac without the
     developer tools, `/usr/bin/git` is a stub that offers to install them: a dialog on every farmy command.
   - On macOS the shim now runs git only when `xcode-select -p` succeeds. Otherwise it passes no Git identity:
     `start` without `.env` is then refused as record 1030 says, and `init` asks for the identity as before.
3. **Tidy paths.**
   - Problem: a trailing `/` or a `//` in `HOME` or an `XDG_*` value made the mount path differ from the one Docker
     reports, so the control container was replaced on every command.
   - The shim now tidies every folder path it resolves before it mounts or hands it over.
4. **No `HOME`, no default home.**
   - Problem: with `HOME` unset (a program started by a service manager), the default home became
     `/.config/farmy`, and a root process created it at the root of the disk.
   - The shim and farmy now refuse instead, with exit 1. The message names `HOME`, and `XDG_CONFIG_HOME` /
     `XDG_STATE_HOME`, `FARMY_DIR` or `-C` as the ways out. Nothing is created and no container is started.
   - This applies only when the default home is reached and a path needs `HOME`.
5. **The shim's own environment stays as it was.**
   - Problem: the shim exported `XDG_CONFIG_HOME` and `XDG_STATE_HOME`, so the host commands it runs saw them (the
     unlock command, `security`, `secret-tool`). A tool that uses XDG only when it is set then looks somewhere
     else for its values.
   - The shim now passes them on the `docker exec` only.
6. **Temporary files stay out of git.**
   - Problem: `egress allow` and `toolbox bump` write a temporary file beside the file they replace, then rename
     it over it. A crash can leave one behind, in a folder that is kept in git.
   - farmy's temporary files there are named `.<file>.<anything>.tmp`, and the `.gitignore` gains the line `.*.tmp`.

## Reported to the owner, not changed here

- **Switching folders replaces the control container.** There is one control container; moving between a
  project folder and the default home replaces it and ends what ran in it: the session, unlocked values, factory
  runs. This behaviour is older than this branch, but `cd` alone now reaches it.
- **Docker Desktop might name bind sources differently** (`/host_mnt/…`). The container would then be replaced
  on every command. To check on a Mac: `docker inspect -f '{{json .Mounts}}' farmy`.
- **Root-owned files during a first session (Docker Engine on Linux).** Files farmy creates are handed to their
  owner when a command ends. A first bare `farmy` attaches a session before it ends, so until then `farmy.yml`
  and `services/` belong to root.
- **Compose fragments.** In the default home, relative bind sources in compose fragments resolve under the state
  folder.
- **farmy.yml copies inside `.work/<name>/`** count as a project folder when farmy runs from there.
- **A symlinked `farmy.yml`** (stow style) points outside the mounts.
- **`help` through the shim** still creates the default home and starts the control container.

## Scenario list

1. The shim tidies the paths it resolves: an `XDG_CONFIG_HOME` with a trailing slash still mounts and hands over
   `~/.config/farmy` and `~/.config` (`shim_folders_test.rb`).
2. With `HOME` unset and no folder named, the shim refuses, names `HOME`, and starts no control container
   (`shim_folders_test.rb`).
3. With `HOME` unset and no folder named, farmy refuses to use a default home and names `HOME`
   (`default_home_test.rb`).
4. When the folder in use lies inside a Git repository on the host, the shim hands farmy that repository's top
   folder as `FARMY_HOST_GIT_TOP` (`shim_folders_test.rb`).
5. Outside any Git repository, the shim hands farmy no `FARMY_HOST_GIT_TOP` (`shim_folders_test.rb`, a guard).
6. On a Mac without the developer tools, the shim runs no git, so macOS never offers to install them, and passes no
   identity (`shim_folders_test.rb`).
7. On a Mac with the developer tools, the shim passes the host's Git identity (`shim_folders_test.rb`, a guard).
8. The commands the shim runs on the host see `XDG_CONFIG_HOME` and `XDG_STATE_HOME` as the user left them: an
   unlock command sees neither set (`shim_folders_test.rb`).
9. `farmy config git` makes no repository when `FARMY_HOST_GIT_TOP` names the repository the folder lies in, and
   names it (`config_home_test.rb`).
10. On a terminal, set-up asks nothing and makes no repository when `FARMY_HOST_GIT_TOP` says the folder already
    lies in one (`config_home_test.rb`).
11. The `.gitignore` set-up writes also keeps farmy's temporary files out of git (`config_home_test.rb`).
