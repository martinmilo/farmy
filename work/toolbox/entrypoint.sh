#!/bin/sh
# The app container's entrypoint: as root, make the volumes (the definition's mounts too) the dev user's; then, as dev, set up git (through
# the keys broker for every host with a git route), run a custom toolbox's start.sh, and wait. Farmy's
# layer installs this file in every app image, over any custom toolbox. Farmy's shared Git launcher initializes
# /workspace before the setup command runs. A clone failure leaves this app container up.
# The modes below run one step and return; farmy labels the image with them when it builds the toolbox
# and runs only a mode the label names (an entrypoint without a mode would start up and never return).
# --git-config (as root): the system Git defaults and routes, then it returns.
# farmy-entrypoint-modes: git-config
set -e
# System defaults never replace or write the user's global configuration. More-specific personal
# URL rewrites receive matching system routes, so Git's longest-prefix selection still uses the broker.
configure_git() {
  [ -n "${GIT_USER_NAME:-}" ] && git config --system user.name "$GIT_USER_NAME"
  [ -n "${GIT_USER_EMAIL:-}" ] && git config --system user.email "$GIT_USER_EMAIL"
  git config --system --replace-all safe.directory /workspace
  for pair in ${DEV_GIT_ROUTES:-} ${DEV_GIT_SSH_ROUTES:-}; do
    from=${pair%%=*}; from=${from%/}/; to=${pair#*=}
    git config --system --replace-all "url.${to}.insteadOf" "$from"
    HOME=/home/dev git config --global --get-regexp '^url\..*\.insteadof$' 2>/dev/null |
      while IFS=' ' read -r key prefix; do
        case "$prefix" in "$from"*)
          suffix=${prefix#"$from"}
          git config --system --replace-all "url.${to}${suffix}.insteadOf" "$prefix" || exit 1
          ;;
        esac
      done
  done
  sshcmd="ssh -o StrictHostKeyChecking=accept-new"
  case "${ALL_PROXY:-}" in
    socks5*://*) proxy=${ALL_PROXY#*://}; proxy=${proxy%/}; sshcmd="$sshcmd -o ProxyCommand='nc -X 5 -x $proxy %h %p'" ;;
    *) case "${HTTPS_PROXY:-}" in
         http://*) proxy=${HTTPS_PROXY#http://}; proxy=${proxy%/}; sshcmd="$sshcmd -o ProxyCommand='nc -X connect -x $proxy %h %p'" ;;
       esac ;;
  esac
  git config --system core.sshCommand "$sshcmd"
}
if [ "${1:-}" = --git-config ]; then configure_git; exit; fi
if [ "$(id -u)" = 0 ]; then
  configure_git
  chown dev:dev /workspace 2>/dev/null || true
  # the shared volume (farmy-shared) and the service's own agents volume start out root's on first use
  for p in /home/dev /home/dev/.farmy-shared /home/dev/.farmy-shared/tool-data /home/dev/.farmy-service; do
    [ -d "$p" ] || continue
    if [ "$(stat -c %u "$p" 2>/dev/null || echo 0)" = 0 ]; then chown dev:dev "$p" 2>/dev/null || true; fi
  done
  # the definition's mounts (DEV_MOUNTS): a volume that starts out root's becomes the dev user's
  for p in ${DEV_MOUNTS:-}; do
    mkdir -p "$p" 2>/dev/null || true
    if [ "$(stat -c %u "$p" 2>/dev/null || echo 0)" = 0 ]; then chown -R dev:dev "$p" 2>/dev/null || true; fi
  done
  drop=$(cat /usr/local/lib/farmy-drop 2>/dev/null || echo gosu)
  exec "$drop" dev env HOME=/home/dev "$0" "$@"
fi
export HOME=${HOME:-/home/dev}
# farmy-shared: what a tool keeps per user, once for every container, a folder per tool. Each agent's login
# paths (agents.tsv) become links into it; the editor servers' extensions too. Project state stays per
# service: an agent's state paths (its transcripts, sessions) are links into the service's own volume.
# FARMY_LOGIN_DIR: where the logins live, farmy-shared by default; a service with shared_logins: false gets
# /home/dev/.farmy-service/logins, on its own agents volume, and no farmy-shared at all
SHARED=${FARMY_LOGIN_DIR:-/home/dev/.farmy-shared}
SERVICE=/home/dev/.farmy-service
mkdir -p "$SHARED" 2>/dev/null || true
AGENTS_TSV=/etc/farmy/agents.tsv
link_into() {  # $1: the path in HOME, $2: where it lives from now on (moved there once, then linked), $3: dir | file
  mkdir -p "$(dirname "$2")" 2>/dev/null || return 0
  # a file's target is a file: an empty folder an earlier farmy made there gives way
  if [ "${3:-dir}" = file ] && [ -d "$2" ] && [ -z "$(ls -A "$2" 2>/dev/null)" ]; then rmdir "$2" 2>/dev/null || true; fi
  [ -L "$1" ] && [ -e "$2" ] && return 0
  if [ -e "$1" ] && [ ! -L "$1" ] && [ ! -e "$2" ]; then mv "$1" "$2" 2>/dev/null || { cp -a "$1" "$2" 2>/dev/null; rm -rf "$1"; }; fi
  if [ ! -e "$2" ]; then
    if [ "${3:-dir}" = file ]; then : > "$2" 2>/dev/null || true; else mkdir -p "$2" 2>/dev/null || true; fi
  fi
  mkdir -p "$(dirname "$1")" 2>/dev/null || true
  rm -rf "$1" 2>/dev/null; ln -s "$2" "$1" 2>/dev/null || true
}
agent_field() {  # $1: agent, $2: column (2 install_apt … 4 login 5 state 6 mcp_add 7 hooks_file 8 hooks_events 9 process)
  grep "^$1	" "$AGENTS_TSV" 2>/dev/null | head -1 | cut -f"$2"
}
if [ -d "$SHARED" ]; then
  for agent in ${FARMY_AGENTS:-}; do
    mkdir -p "$SHARED/$agent" 2>/dev/null || true
    first=""
    for entry in $(agent_field "$agent" 4 | tr ':' ' '); do
      # agents.tsv writes a folder with a trailing / and a file without
      case "$entry" in */) kind=dir ;; *) kind=file ;; esac
      p=${entry%/}
      base=$(basename "$p")
      # the shared folder as earlier farmy versions filled it (the login's files directly in it) moves under its name
      if [ -z "$first" ] && [ ! -e "$SHARED/$agent/$base" ] && [ -n "$(ls -A "$SHARED/$agent" 2>/dev/null)" ]; then
        mkdir -p "$SHARED/$agent/.farmy-move" && find "$SHARED/$agent" -mindepth 1 -maxdepth 1 ! -name .farmy-move -exec mv {} "$SHARED/$agent/.farmy-move/" \; && mv "$SHARED/$agent/.farmy-move" "$SHARED/$agent/$base"
      fi
      link_into "/home/dev/$p" "$SHARED/$agent/$base" "$kind"
      [ -n "$first" ] || first=$p
    done
    if [ -d "$SERVICE" ]; then
      mkdir -p "$SERVICE/$agent" 2>/dev/null || true
      for st in $(agent_field "$agent" 5 | tr ',' ' '); do
        [ -n "$first" ] || break
        link_into "/home/dev/$first/$st" "$SERVICE/$agent/$st"
      done
    fi
  done
  arch=$(uname -m 2>/dev/null || echo unknown)
  for ed in vscode:.vscode-server cursor:.cursor-server; do
    name=${ed%%:*}; srv="/home/dev/${ed#*:}"; shared="$SHARED/${name}/linux-${arch}"
    mkdir -p "$shared/extensions" "$srv" 2>/dev/null || true
    [ -L "$srv/extensions" ] || { rm -rf "$srv/extensions" 2>/dev/null; ln -s "$shared/extensions" "$srv/extensions" 2>/dev/null || true; }
  done
fi
# The defaults and managed URL routes were written at system scope before dropping privileges.
if [ -n "${DEV_GIT_ROUTES:-}" ]; then
  i=0; until curl -fsS -o /dev/null "http://keys:9181/-/health" 2>/dev/null || [ "$i" -ge 30 ]; do sleep 1; i=$((i+1)); done
fi
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  i=0; until [ -S "$SSH_AUTH_SOCK" ] || [ "$i" -ge 30 ]; do sleep 1; i=$((i+1)); done
fi
# each agent: the knowledge MCP registered once per login (mcp_add, with FARMY_MCP_URL), its status hooks
# written when the hooks file has none yet (they call farmy-agent-status <agent> <state>, read by farmy status)
for agent in ${FARMY_AGENTS:-}; do
  mcp_add=$(agent_field "$agent" 6)
  if [ -n "${FARMY_MCP_URL:-}" ] && [ -n "$mcp_add" ] && [ -d "$SHARED/$agent" ] && [ ! -e "$SHARED/$agent/.farmy-mcp-added" ]; then
    ( FARMY_MCP_URL="$FARMY_MCP_URL" sh -c "$mcp_add" >/dev/null 2>&1 && touch "$SHARED/$agent/.farmy-mcp-added" ) &
  fi
  hooks_file=$(agent_field "$agent" 7); hooks_events=$(agent_field "$agent" 8)
  if [ -n "$hooks_file" ] && [ -n "$hooks_events" ]; then
    f="/home/dev/$hooks_file"
    if [ ! -e "$f" ]; then
      mkdir -p "$(dirname "$f")" 2>/dev/null || true
      {
        printf '{\n  "hooks": {\n'
        sep=""
        for ev in $(printf '%s' "$hooks_events" | tr ',' ' '); do
          printf '%s    "%s": [{"hooks": [{"type": "command", "command": "farmy-agent-status %s %s"}]}]' "$sep" "${ev%%=*}" "$agent" "${ev#*=}"
          sep=",
"
        done
        printf '\n  }\n}\n'
      } > "$f"
    elif ! grep -q farmy-agent-status "$f" 2>/dev/null; then
      echo "note: $f has no farmy-agent-status hooks — farmy status falls back to the process list for $agent"
    fi
    [ -d "$SERVICE/$agent" ] && [ ! -e "$SERVICE/$agent/agent.status" ] && farmy-agent-status "$agent" idle 2>/dev/null || true
  fi
done
# localhost forwarders: ${port:x} / ${url:x} in the definition reach the host from inside too
if [ -n "${DEV_FORWARD_PORTS:-}" ] && command -v socat >/dev/null 2>&1; then
  for p in $DEV_FORWARD_PORTS; do socat "TCP-LISTEN:$p,fork,reuseaddr,bind=127.0.0.1" "TCP:host.docker.internal:$p" >/dev/null 2>&1 & done
fi
# a custom toolbox's own startup (its toolbox/start.sh, installed here by farmy's layer): as dev, from the
# home folder, at every start; a failure is reported with its exit status and the container stays up
START_SH=/usr/local/lib/farmy/toolbox-start.sh
if [ -f "$START_SH" ]; then
  rc=0
  (cd "$HOME" && "$START_SH") || rc=$?
  [ "$rc" = 0 ] || echo "farmy-entrypoint: toolbox start.sh failed with exit status $rc; the container stays up" >&2
fi
echo "$(whoami)@$(hostname) ready."
exec tail -f /dev/null
