#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/home"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

backup_path() {
  local p="$1"
  if [[ -e "$HOME/$p" || -L "$HOME/$p" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$p")"
    cp -a "$HOME/$p" "$BACKUP_DIR/$p"
  fi
}

apply_path() {
  local p="$1"
  if [[ -d "$SRC/$p" ]]; then
    mkdir -p "$HOME/$p"
    # Merge directory contents without creating nested duplicate paths.
    tar -C "$SRC/$p" -cf - . | tar -C "$HOME/$p" -xf -
  else
    mkdir -p "$HOME/$(dirname "$p")"
    cp -a "$SRC/$p" "$HOME/$p"
  fi
}

while IFS= read -r -d '' file; do
  rel="${file#$SRC/}"
  backup_path "$rel"
  apply_path "$rel"
done < <(find "$SRC" -mindepth 1 -maxdepth 1 -print0)

# user services (best-effort)
if [[ -d "$HOME/.config/systemd/user" ]]; then
  systemctl --user daemon-reload || true
  for svc in tether-monitor.service voice-interrupt-daemon.service crypto-tui.service voice-handsfree-daemon.service; do
    if [[ -f "$HOME/.config/systemd/user/$svc" ]]; then
      systemctl --user enable --now "$svc" || true
    fi
  done
fi

# Ensure executables
find "$HOME/.config/hypr/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
find "$HOME/waybar-scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
find "$HOME/waybar-scripts" -type f -name '*.py' -exec chmod +x {} + 2>/dev/null || true

echo "Dotfiles applied. Backups: $BACKUP_DIR"
