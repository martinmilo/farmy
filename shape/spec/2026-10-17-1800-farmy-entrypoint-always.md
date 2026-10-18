# Every app image runs farmy's own entrypoint; custom startup goes into toolbox/start.sh

On the owner's machine `farmy rebuild private` produced an image the exec guard refused, and the guard
said "built by an older farmy: farmy rebuild private", the command that had just run. Cause (read-only
investigation of work/): the containers folder had a `toolbox/` folder with a Dockerfile (an older
farmy's work/ folder), so farmy built that custom toolbox, silently; the modes label was read from that
folder's entrypoint.sh, which predates modes; farmy's own layer never installs its entrypoint. Any
custom toolbox without the modes line, or with a Dockerfile that installs another entrypoint, ended the
same way, and `farmy rebuild` could never get out of it.

Decided (the owner, 2026-10-17), option A:
- farmy's layer always installs farmy's own entrypoint as /usr/local/bin/farmy-entrypoint, last, over
  any custom toolbox, and makes it the image's ENTRYPOINT. A rebuild therefore always gives an image the
  guard accepts, and "farmy rebuild <name>" is always a fix that works.
- The `farmy.entrypoint.modes` label is read from the entrypoint actually installed (farmy's), never from
  a file a custom toolbox brings.
- Custom startup logic goes into `toolbox/start.sh` in the custom toolbox: farmy's entrypoint runs it as
  dev at every container start, after farmy's own startup. Documented in place of custom entrypoints.
- start (and rebuild) say when they build a custom toolbox from the containers folder, naming the folder.

Tests: FarmyEntrypointTest (five): the custom-toolbox notice; a custom toolbox with an entrypoint from
before modes still gets farmy's and dotfiles are applied; after the older-image message, the farmy
rebuild it names makes the next pull apply (no loop); the label comes from the installed entrypoint, not
a custom toolbox's claims; a custom toolbox's start.sh runs as dev at container start.
