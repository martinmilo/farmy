#!/bin/sh
# Run as dev, with the service's persistent private HOME. No personal data is migrated.
set -eu
: "${HOME:?HOME is required}"
shared="$HOME/.farmy-shared"
case $(uname -m) in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo 'farmy home: unsupported architecture' >&2; exit 1 ;; esac
libc=glibc
if ldd --version 2>&1 | grep -qi musl; then libc=musl; fi
for loader in /lib/ld-musl-*.so.1; do [ ! -e "$loader" ] || libc=musl; done
versions=$(printf '%s' "${FARMY_TOOL_VERSIONS:-none}" | sha256sum | cut -d' ' -f1)
data="$shared/tool-data/linux-$arch-$libc/$versions"
for name in ${FARMY_SHARED_DATA-nvim}; do
  case $name in ''|.|..|*[!a-zA-Z0-9_.-]*) echo "farmy home: shared_data '$name' must be a directory name" >&2; exit 1 ;; esac
  for kind in share cache; do
    if [ "$kind" = share ]; then target="$HOME/.local/share/$name"; else target="$HOME/.cache/$name"; fi
    source="$data/$kind/$name"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then continue; fi
    if [ -L "$target" ]; then
      case $(readlink "$target") in "$shared"/tool-data/*) rm "$target" ;; esac
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then

      if [ -d "$target" ] && [ ! -L "$target" ] && [ -z "$(ls -A "$target")" ]; then rmdir "$target";
      else echo "farmy home: $target contains existing data; explicit migration is required before enabling shared_data" >&2; exit 1; fi
    fi
    mkdir -p "$source" "$(dirname "$target")"
    ln -s "$source" "$target"
  done
done
repo=${FARMY_DOTFILES_DIR:-$shared/dotfiles}
[ -d "$repo/.git" ] || exit 0
if [ -n "${FARMY_DOTFILES_INSTALL:-}" ]; then
  case $FARMY_DOTFILES_INSTALL in /*|../*|*/../*|*/..) echo 'farmy dotfiles: install must be repository-relative' >&2; exit 1 ;; esac
  cd "$repo"
  [ -x "$FARMY_DOTFILES_INSTALL" ] || { echo "farmy dotfiles: installer $FARMY_DOTFILES_INSTALL is not executable" >&2; exit 1; }
  exec "./$FARMY_DOTFILES_INSTALL"
fi
backup_root=
backup() {
  if [ -z "$backup_root" ]; then
    mkdir -p "$HOME/.dotfiles-backup"
    backup_root=$(mktemp -d "$HOME/.dotfiles-backup/$(date -u +%Y%m%dT%H%M%S)-XXXXXX")
    echo "farmy dotfiles: backup $backup_root"
  fi
  mkdir -p "$backup_root/$(dirname "$1")"
  mv "$HOME/$1" "$backup_root/$1"
}
protected() {
  for managed in ${FARMY_SHARED_DATA-nvim}; do
    case $1 in ".local/share/$managed"|".cache/$managed") return 0 ;; esac
  done
  return 1
}
merge_dotfile() {
  local relative=$1 source="$repo/$1" target="$HOME/$1" child
  protected "$relative" && return 0
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then return 0; fi
  if [ -d "$source" ] && [ ! -L "$source" ]; then
    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -d "$target" ]; }; then backup "$relative"; fi
    mkdir -p "$target"
    for child in "$source"/* "$source"/.[!.]* "$source"/..?*; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      merge_dotfile "$relative/${child##*/}"
    done
  else
    if [ -d "$target" ] && [ ! -L "$target" ]; then echo "farmy dotfiles: cannot replace unmergeable directory $target" >&2; exit 1; fi
    if [ -e "$target" ] || [ -L "$target" ]; then backup "$relative"; fi
    mkdir -p "$(dirname "$target")"
    ln -s "$source" "$target"
  fi
}
for file in "$repo"/.[!.]* "$repo"/..?*; do
  [ -e "$file" ] || [ -L "$file" ] || continue
  name=${file##*/}
  case $name in .git|.gitignore|.gitattributes|.gitmodules|.github|.gitlab|.gitlab-ci.yml|.forgejo|.gitea) continue ;; esac
  merge_dotfile "$name"
done
