#!/bin/sh
set -eu
revision=$(git rev-parse HEAD)
if [ -f "$HOME/fail-dotfiles" ]; then
  echo "requested installer failure" >&2
  exit 12
fi
if [ -f "$HOME/fail-dotfiles-quietly" ]; then
  exit 12
fi
if [ -f "$HOME/hang-dotfiles" ]; then
  exec sleep 600
fi
test -d "$HOME/.local/share/nvim"
printf '%s\t%s\t%s\t%s\n' "$(id -un)" "$HOME" "$PWD" "$revision" >> "$HOME/.dotfiles-installations"
ln -sfn "$PWD/.zshrc" "$HOME/.zshrc"
