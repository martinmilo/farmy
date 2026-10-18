# The knowledge container

An agent inside an app container cannot run farmy or docker, and should not. What it can do is
ask: the knowledge container `farmy-knowledge` serves farmy's docs, the containers folder's definitions and
the latest status over MCP, read-only, to every app container.

## What it is

The `farmy-knowledge` binary in `farmy-knowledge:local`, one container named `farmy-knowledge` on the
`farmy` network (the control container is `farmy`), started with the first service and stopped with `farmy stop` (no name). It
listens on 9190 for MCP over HTTP (JSON-RPC at `/mcp`, `/-/health`). It has no Docker socket and
runs no command; its answers tell the agent which farmy command to run in the session.

Under `/kb`: farmy's `README.md` and `docs/`, copied into the image; mounted read-only, the containers folder's
`services/`, and `.work/status` (the snapshot). Never `.work/<name>/`, never a
secret: there is none to find there anyway.

`knowledge: false` in `farmy.yml` turns it off: no container, no network membership, no
`FARMY_MCP_URL` in the app containers.

## Tools

| Tool | What it answers |
|---|---|
| `status` | every service, its state, its addresses, its containers, the notes, and how old the snapshot is |
| `service` (name) | the definition `services/<name>.yml`, the port block, the service's status line |
| `list_docs` | the documents with their first heading |
| `read_doc` (name) | one document, e.g. `docs/credentials.md` or `services/shop.yml` |
| `search_docs` (query) | case-insensitive `file:line` matches across all of them |

## The agents

For every agent on for the service whose entry has an `mcp_add` line (Claude Code, Codex, Gemini
CLI, Copilot in the catalogue), the entrypoint runs it once per login with `FARMY_MCP_URL`
(`http://farmy-knowledge:9190/mcp`); the registration lives with the login on `farmy-shared`, so
it is done once for every container. Ask Claude "what's running in
farmy?" and it calls `status`. Other agents point at `http://farmy-knowledge:9190/mcp` themselves.

## The snapshot

farmy writes `.work/status/status.tsv` after `start`, `stop`, `destroy` and `status`:

```
generated   <RFC 3339 time, UTC>
service     <name>  <running|stopped>  <addresses>  <container=state,...>
problem     <name>  <definition changed — run farmy restart shop>
```

The snapshot is as old as the last farmy command; the agent sees the time and can ask for
`farmy status` to be run.
