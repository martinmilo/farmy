# Editors

The app container is a normal container with a `dev` user and the checkout at `/workspace`; any
editor that attaches to a running container works with it. farmy does not open an editor itself.

## VS Code and Cursor

With the Dev Containers extension: "Attach to Running Container…", pick `shop`, open `/workspace`.
Attach as `dev`, not root: the extension's "Attached Container Configuration" for `shop` should hold

```json
{ "workspaceFolder": "/workspace", "remoteUser": "dev" }
```

farmy also writes `.work/shop/.devcontainer/devcontainer.json` next to the compose file, with the
service, the folder and the user set, for editors that read one. Prefer attaching: "Reopen in
Container" on that file may start a second compose stack.

Extensions are shared through the `farmy-shared` volume (README → Volumes): the entrypoint links
each editor server's `extensions` folder (`~/.vscode-server`, `~/.cursor-server`) to a bucket on
the volume, per editor and architecture, so an extension installed in one service's container is there in every
other, and survives `farmy destroy`. The rest of each editor's server stays local to the
container. Compiled extensions are built for one libc: a bucket filled from a Debian container
can break in an Alpine one and the other way round; keep services that share the bucket on one
base family, or give one of them a toolbox of its own without the link. To start over with an
empty bucket, remove the folder on the volume while nothing runs (`farmy-shared` also holds the
logins, so do not remove the volume itself).

## In the terminal

`farmy ssh shop` is a zsh (or bash) as dev in `/workspace`, or in the `workdir:` when the
definition has one. The toolbox installs git, curl, bash and zsh; add what you want in a
`toolbox/` of your own (README → Toolbox). `farmy run shop <words>` runs one command the same way.

## From another machine

Everything above works over ssh to the host: `ssh mini`, then `farmy` for the
session (it finds `~/.config/farmy` from any folder), or `farmy ssh shop` for a shell. VS Code Remote-SSH to the host and then "Attach to
Running Container" gives the editor the same view.
