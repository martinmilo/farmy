#!/bin/sh
# What the toolbox puts into the service's image, with the image's own package manager:
# the basics, the dev user (uid 1001, so the shared volumes have one owner), the agents.
# apt (Debian, Ubuntu) is the supported path; apk (Alpine) is best effort. The agents come from
# /etc/farmy/agents.tsv (name, install on apt, install on apk, login, state, mcp_add, hooks file,
# hooks events, process; tab-separated): each agent named in $1 is installed with its line for this base.
set -eu
AGENTS=${1:-}
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends git curl wget ca-certificates bash zsh socat netcat-openbsd openssh-client gosu build-essential pkg-config gnupg xz-utils unzip
  rm -rf /var/lib/apt/lists/*
  DROP=gosu; BASE=apt
elif command -v apk >/dev/null 2>&1; then
  # libgcc and libstdc++: what Claude Code needs on Alpine (with USE_BUILTIN_RIPGREP=0, set in the Dockerfile)
  apk add --no-cache git curl wget ca-certificates bash zsh socat netcat-openbsd openssh-client su-exec build-base pkgconf shadow libgcc libstdc++ tar gzip xz unzip
  DROP=su-exec; BASE=apk
  echo 'export USE_BUILTIN_RIPGREP=0' > /etc/profile.d/farmy-alpine.sh
else
  echo "farmy toolbox: neither apt-get nor apk in this image — bring your own toolbox/ (README → Toolbox)" >&2
  exit 1
fi
echo "$DROP" > /usr/local/lib/farmy-drop   # how the entrypoint drops to the dev user
# the dev user, uid 1001 (official images put their own user at 1000); an image that already has uid 1001
# under another name has that user renamed, so the shared volumes keep one owner across every service
if ! id dev >/dev/null 2>&1; then
  taken=$(getent passwd 1001 | cut -d: -f1 || true)
  if [ -n "$taken" ]; then
    usermod -l dev -d /home/dev -m "$taken" 2>/dev/null || { sed -i "s/^$taken:/dev:/" /etc/passwd; mkdir -p /home/dev; }
    groupmod -n dev "$(getent group 1001 | cut -d: -f1)" 2>/dev/null || true
  else
    groupadd -g 1001 dev 2>/dev/null || addgroup -g 1001 dev
    useradd -m -u 1001 -g 1001 -s /bin/zsh dev 2>/dev/null || adduser -D -u 1001 -G dev -s /bin/zsh dev
  fi
  usermod -s /bin/zsh dev 2>/dev/null || true
fi
mkdir -p /home/dev /home/dev/.local/bin /workspace && chown -R dev:dev /home/dev /workspace
[ -d /usr/local/bundle ] && chown -R dev:dev /usr/local/bundle || true
printf '# zsh additions go here; farmy adds nothing.\n' > /home/dev/.zshrc && chown dev:dev /home/dev/.zshrc
echo 'export PATH="/home/dev/.local/bin:$PATH"' > /etc/profile.d/farmy-path.sh
# an agent's activity for farmy status / the session: the agent's hooks (written once by the entrypoint)
# call this with <agent> working | waiting | idle; it writes the state and the time to the agent's folder
# on the service's own volume
cat > /usr/local/bin/farmy-agent-status <<'EOS'
#!/bin/sh
d=/home/dev/.farmy-service/${1:-}
[ -n "${1:-}" ] && [ -d "$d" ] || exit 0
printf '%s\t%s\n' "${2:-idle}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$d/agent.status.tmp" && mv -f "$d/agent.status.tmp" "$d/agent.status"
EOS
chmod 755 /usr/local/bin/farmy-agent-status
# the agents: the install line of this base, run as root (a per-user installer says `su dev -c …` itself)
for agent in $AGENTS; do
  line=$(grep "^$agent	" /etc/farmy/agents.tsv 2>/dev/null | head -1 || true)
  if [ -z "$line" ]; then echo "farmy toolbox: no line for '$agent' in agents.tsv — skipped" >&2; continue; fi
  if [ "$BASE" = apt ]; then cmd=$(printf '%s\n' "$line" | cut -f2); else cmd=$(printf '%s\n' "$line" | cut -f3); fi
  if [ -z "$cmd" ]; then echo "farmy toolbox: $agent has no install line for an $BASE base — not installed (FORMATS.md → Agents)" >&2; continue; fi
  echo "farmy toolbox: installing $agent: $cmd"
  sh -c "$cmd"
done
