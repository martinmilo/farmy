#!/bin/sh
# Run by the toolbox's Dockerfile as dev (USER dev), once install.sh has installed the agents: each
# agent's version line (agents.tsv's version column) as the user who will run it, as a factory run asks
# it (`sh -c <version>`). One that fails fails the build, naming the agent and what the command said, so
# a CLI dev cannot run (one under /root, say) fails here instead of in a run (FORMATS.md → Agents). Each line
# gets 30 s (`timeout 30`: coreutils on Debian, busybox on Alpine); one that does not answer in time fails the
# build, naming the agent and the limit, instead of hanging it.
# An agent with no version line, or none installed on this base, is not checked. HOME is a scratch
# folder for the check, so nothing the CLIs write when asked stays in the image.
set -eu
AGENTS=${1:-}
if [ "$(id -u)" = 0 ]; then
  echo "farmy toolbox: the agents' check runs as dev, not as root" >&2
  exit 1
fi
if command -v apt-get >/dev/null 2>&1; then install_column=2; else install_column=3; fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failed=0
for agent in $AGENTS; do
  line=$(grep "^$agent	" /etc/farmy/agents.tsv 2>/dev/null | head -1 || true)
  [ -n "$line" ] || continue
  [ -n "$(printf '%s\n' "$line" | cut -f"$install_column")" ] || continue
  version=$(printf '%s\n' "$line" | cut -f10)
  if [ -z "$version" ]; then
    echo "farmy toolbox: $agent has no version line — not checked as dev"
    continue
  fi
  # the output goes to a file, not a pipe, so a process the line leaves behind cannot hold the check open
  started=$(date +%s)
  (cd "$scratch" && HOME="$scratch" timeout 30 sh -c "$version" </dev/null >"$scratch/.said" 2>&1) && code=0 || code=$?
  ended=$(date +%s)
  said=$(cat "$scratch/.said")
  last=$(printf '%s\n' "$said" | sed '/^[[:space:]]*$/d' | tail -n 1)
  if [ "$code" = 0 ]; then
    echo "farmy toolbox: $agent runs as dev: $last"
  elif [ "$code" = 124 ] || [ $((ended - started)) -ge 30 ]; then
    # coreutils' timeout exits 124; busybox's (Alpine) leaves the killed command's own status (143), so
    # the elapsed time decides there
    [ -z "$said" ] || printf '%s\n' "$said" >&2
    echo "farmy toolbox: $agent did not answer \`$version\` as dev within 30 s (timeout 30): the build stops instead of hanging" >&2
    failed=1
  else
    [ "$(printf '%s\n' "$said" | sed '/^[[:space:]]*$/d' | wc -l)" -le 1 ] || printf '%s\n' "$said" >&2
    echo "farmy toolbox: $agent cannot be run by dev: \`$version\` exited $code: ${last:-(no output)}" >&2
    failed=1
  fi
done
exit "$failed"
