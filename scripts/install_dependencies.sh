#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="$ROOT_DIR/manifests"

sudo pacman -Syu --noconfirm
sudo pacman -S --needed --noconfirm git base-devel curl wget unzip tar stow python python-pip pipx nodejs npm

# Split official vs AUR (aur list may be empty)
OFFICIAL_TMP="$(mktemp)"
if [[ -s "$MANIFESTS/aur-explicit.txt" ]]; then
  comm -23 <(sort "$MANIFESTS/pacman-explicit.txt") <(sort "$MANIFESTS/aur-explicit.txt") > "$OFFICIAL_TMP"
else
  cp "$MANIFESTS/pacman-explicit.txt" "$OFFICIAL_TMP"
fi

if [[ -s "$OFFICIAL_TMP" ]]; then
  sudo pacman -S --needed --noconfirm $(tr '\n' ' ' < "$OFFICIAL_TMP")
fi

if [[ -s "$MANIFESTS/aur-explicit.txt" ]]; then
  if ! command -v yay >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
    (cd "$tmpdir/yay" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"
  fi
  yay -S --needed --noconfirm $(tr '\n' ' ' < "$MANIFESTS/aur-explicit.txt")
fi

# pipx packages
if [[ -s "$MANIFESTS/pipx.txt" ]]; then
  while read -r pkg version; do
    [[ -z "${pkg:-}" ]] && continue
    pipx install --force "$pkg" || true
  done < "$MANIFESTS/pipx.txt"
fi

# npm globals
if [[ -s "$MANIFESTS/npm-global-packages.txt" ]]; then
  npm install -g $(tr '\n' ' ' < "$MANIFESTS/npm-global-packages.txt") || true
fi

# Voice assistant virtualenv requirements (optional)
if [[ -s "$MANIFESTS/voice-venv-requirements.txt" ]]; then
  python -m venv "$HOME/.config/hypr/voice/venv"
  "$HOME/.config/hypr/voice/venv/bin/pip" install -U pip
  "$HOME/.config/hypr/voice/venv/bin/pip" install -r "$MANIFESTS/voice-venv-requirements.txt" || true
fi

echo "Dependencies installed."
