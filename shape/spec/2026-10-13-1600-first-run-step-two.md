# 2026-10-13 16:00 — First run, step 2: what the Mini found

Step 2 of the first run passed end to end: the control image was rebuilt on a hash change, `farmy
add` wrote the definition, the helper images built, the toolbox built on `debian:bookworm-slim`
with Claude Code inside, the containers came up, the clone ran, `status` and `run` work. Five
findings, fixed here and nothing else.

## Decided

1. **Nothing farmy generates bind-mounts a path of the control container.** The daemon resolves a
   bind source on the host; the containers folder is mounted in the control container at its host
   path, so a path under it is fine, and any other path (`/opt/farmy/README.md`, which only the
   control container has) is not. The knowledge image carries farmy's `README.md` and `docs/`
   itself, under `/kb`; the containers folder's `services/` and `.work/status` stay bind mounts.
   A test checks every container farmy starts: each bind source is inside the containers folder.
2. **The control image has the buildx plugin**, so builds go through BuildKit and stop printing the
   legacy-builder warning with the whole apt log. An integration test checks `docker buildx version`
   in the control container.
3. **Docker's CLI hints are off** (`DOCKER_CLI_HINTS=false`) in the shim's own docker calls and in
   the control container's environment, so Docker Desktop's "What's next" line never appears.
4. **A service without ports says so at the end of `start`**: `<name>: no ports published` instead
   of an arrow with nothing after it.
5. **The work folder had a `ports.yml` and a `services/` from a farmy run inside it.** Removed; farmy
   is run in a containers folder, never in the checkout.

## Scenario list

start_test.rb
- every bind mount of a container farmy starts is inside the containers folder, never farmy's own files

shim_test.rb
- the control container runs with Docker's CLI hints off

ports_test.rb
- starting a service without ports says that nothing is published

integration_test.rb
- the control image has docker buildx
