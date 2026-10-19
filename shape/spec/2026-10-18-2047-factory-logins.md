# Factory logins: a subscription login of its own for an agent's factory runs

The owner wants Codex to work as the unattended factory worker on a ChatGPT subscription. Today a factory
agent reaches its model in two ways only: api-key mode (the agent's API route through a broker of the run's
own) or token mode (the provider's secret named by the agent's `token_env`, in its environment). Codex's
`token_env` is `CODEX_API_KEY`, an API key; a ChatGPT login is the file `~/.codex/auth.json`, which the CLI
refreshes during use. The factory agent's container mounts no login at all ("no shared login"), on purpose:
the interactive login in `farmy-shared` serves every app container and must never be raced or exposed by
an unattended run.

Decided (the owner, 2026-10-18), generic for every agent, not Codex-specific:

- **`factory_login`**, a new agent entry field (catalogue or your own in `farmy.yml`):
  `{path: .codex, create: codex login --device-auth}`. `path` is the folder under `$HOME` where the CLI
  keeps its login (relative, no `..`); `create` is the shell line that makes the login without a browser on
  this machine.
- **`farmy factory login <service> <agent>`** creates the agent's factory login: a volume of the agent's
  own, `farmy-factory-login-<agent>`, made the dev user's (1001) by a root `chown` container, then the
  `create` line run in the service's image `farmy/<service>:dev` as dev, with that volume at
  `/home/dev/<path>`, interactive (`-i`, and `-t` on a terminal), on the networks and with the proxy
  environment of the service's app container (it goes out the way the app does). One volume per agent,
  shared by every service on this Docker; a second `farmy factory login` logs in again into the same
  volume. When the command fails on a volume this call created, the volume is removed, so an existing
  volume always means a login was made. Refused: an agent without `factory_login`; a service whose image
  has not been built, or whose image does not carry the agent (naming `farmy start` or the agent).
- **`mode: login`** in a factory profile: the agent's container mounts `farmy-factory-login-<agent>`
  read-write at `/home/dev/<path>`; no token, no broker route, never `farmy-shared`; the same internal
  network and filtering gate as the other modes (the agent's `api_hosts`). `factory start` refuses login
  mode for an agent without `factory_login` (naming the agent and `factory_login`) and before the login
  exists (naming `farmy factory login <service> <agent>`). Login mode is never chosen automatically:
  omitted mode keeps preferring the API route, then the token.
- **One iteration at a time per factory login.** A token refresh rewrites the login file; two agents
  writing it at once could corrupt it or invalidate each other's refresh token. While an agent iteration
  in login mode runs, another run's iteration of the same agent in login mode waits before its agent
  container starts; its phase is `login_wait` (in `factory list` and `show`). Everything else of that run
  (clone, commits, gates) and runs of other agents are not held. The wait does not count against
  `iteration_timeout` (the timeout wraps the agent's container). With `concurrency > 1` this means: runs
  are admitted as before and share the service's slots, but agent iterations of the same factory login
  run one after another; gates and commits still overlap. The turn is kept per containers folder; two
  containers folders on one Docker share the volume but not the turn (documented, not prevented).
- `farmy destroy <service>` never removes a factory login volume (it is the agent's, not the service's).

**Catalogue.** `factory_login` is filled only where the vendor documents a file-based login that a command
creates without a browser and that the unattended run uses (researched 2026-10-18):
- codex: `{path: .codex, create: codex login --device-auth}`: `auth.json` under `CODEX_HOME` (default
  `~/.codex`), file storage when no OS store exists; device-code login, which the account must first enable
  in ChatGPT's security settings; refreshed automatically during use; `codex exec` reuses the saved login
  (https://learn.chatgpt.com/docs/auth, https://learn.chatgpt.com/docs/non-interactive-mode).
- Left out: claude (`~/.claude/.credentials.json` exists, but no documented browserless command creates it;
  token mode with `claude setup-token` remains the way); copilot (a plaintext fallback in `~/.copilot`
  exists, `copilot login` uses a device code, but whether `copilot -p` uses the stored login is not
  documented); gemini (consumer logins ended 2026-06-18); opencode (storage differs between versions);
  cursor (no path documented).

Left out: removing a login (`docker volume rm farmy-factory-login-<agent>` does it); sharing one login
volume across several Docker hosts; a lock across containers folders.

## Asked, not built: a model server on the host or the LAN through enforced egress

The owner asked whether a factory agent can reach an OpenAI-compatible server on the host or the LAN
(Ollama, vLLM) through enforced egress, configured only through the agent entry's `env` and `egress allow`.
Answer (a read-only investigation of work/ for the owner, 2026-10-18):

- `egress allow` never reaches a factory run: factory policy is only the selected agent's `api_hosts`
  ("Enforced egress"). The agent entry's `api_hosts` in `farmy.yml` is the lever; it replaces the catalogue
  list, so the vendor hosts must be listed again if the run still needs them.
- An `api_hosts` entry may be an IP literal with a port (`192.168.1.50:8000`) or a name with a port. The
  gate refuses no private or LAN address, proxies plain `http://` as well as CONNECT, and its outward
  network (`farmy`) can route to the host and the LAN.
- The agent's base URL must go through the gate (the agent is on an internal network; its NO_PROXY holds
  only local peers), so the CLI must honour HTTP(S)_PROXY for that URL.
- Not working today: `host.docker.internal` in the gate resolves only where Docker itself provides that
  name (Docker Desktop, OrbStack); on Docker Engine the factory's gate has no `host-gateway` entry. And with
  a mesh or `egress: {proxy: …}` every allowed request goes to that upstream, never directly, so a LAN
  address works only if the upstream reaches it.
- Outside farmy: the server must listen on an address the Docker bridge reaches (Ollama binds 127.0.0.1
  by default), and Codex accepts only providers speaking the Responses API (`wire_api = "responses"`).

Missing, for a later record if wanted: `--add-host host.docker.internal:host-gateway` on factory (and app)
gates; a way to send listed local destinations directly when an upstream proxy is configured.

## Scenarios (FactoryLoginTest, and one in AgentsTest)

1. farmy factory login runs the agent's factory_login command in the service image, as dev, with the
   agent's own login volume, made the dev user's, at its login path.
2. The login container goes out the way the service's app container does.
3. A login that fails on a new volume removes that volume and reports the command's exit code.
4. farmy factory login for an agent without factory_login is refused, naming factory_login.
5. farmy factory login for an agent the service's image does not carry is refused, naming the agent.
6. A factory agent in login mode mounts its agent's login volume, writable, at the login path, and gets
   no token and no farmy-shared.
7. Login mode before farmy factory login is refused, naming the command that creates the login, and no
   agent runs.
8. Login mode for an agent without factory_login is refused, naming the agent and factory_login.
9. An agent of your own may declare factory_login, and its runs in login mode mount that login.
10. A factory_login path outside the home folder is refused by name.
11. Two runs on the same factory login take turns: the second agent waits in login_wait until the first
    agent ends, though a slot is free.
12. farmy destroy leaves the factory login volumes.
13. (AgentsTest) Codex's catalogue entry declares its factory login: .codex, created by codex login
    --device-auth.
