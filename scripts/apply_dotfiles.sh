#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/home"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
FAIL_COUNT=0

log() { printf '[apply] %s\n' "$*"; }
warn() { printf '[apply][warn] %s\n' "$*" >&2; }
die() { printf '[apply][error] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

sync_file_strict() {
  local src="$1"
  local dst="$2"
  run_cmd mkdir -p "$(dirname "$dst")"
  # --remove-destination avoids edge cases where inplace overwrite can silently fail.
  run_cmd cp -af --remove-destination "$src" "$dst"
}

[[ -d "$SRC" ]] || die "Missing source tree: $SRC"
command -v find >/dev/null 2>&1 || die "find is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

run_cmd mkdir -p "$BACKUP_DIR"

backup_path() {
  local p="$1"
  if [[ -e "$HOME/$p" || -L "$HOME/$p" ]]; then
    if [[ "$p" == ".local" ]]; then
      # Avoid backing up all of ~/.local (can include permission-locked app data).
      if [[ -e "$HOME/.local/share/rofi" ]]; then
        run_cmd mkdir -p "$BACKUP_DIR/.local/share"
        run_cmd cp -a "$HOME/.local/share/rofi" "$BACKUP_DIR/.local/share/rofi"
      fi
      return 0
    fi
    if [[ "$p" == "waybar-scripts" && -d "$HOME/waybar-scripts" ]]; then
      run_cmd mkdir -p "$BACKUP_DIR/waybar-scripts"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: backup waybar-scripts with target exclusions"
      else
        tar -C "$HOME/waybar-scripts" \
          --exclude='traffic_rs/target' \
          --exclude='traffic_rs/target/*' \
          -cf - . | tar -C "$BACKUP_DIR/waybar-scripts" -xf -
      fi
      return 0
    fi
    run_cmd mkdir -p "$BACKUP_DIR/$(dirname "$p")"
    run_cmd cp -a "$HOME/$p" "$BACKUP_DIR/$p"
  fi
}

apply_path() {
  local p="$1"
  if [[ -d "$SRC/$p" ]]; then
    run_cmd mkdir -p "$HOME/$p"
    # Merge directory contents without creating nested duplicate paths.
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN: tar -C $SRC/$p -cf - . | tar --overwrite -C $HOME/$p -xf -"
    else
      tar -C "$SRC/$p" -cf - . | tar --overwrite -C "$HOME/$p" -xf -
    fi
  else
    run_cmd mkdir -p "$HOME/$(dirname "$p")"
    sync_file_strict "$SRC/$p" "$HOME/$p"
  fi
}

enforce_active_waybar_targets() {
  local config_link="$HOME/.config/waybar/config"
  local style_link="$HOME/.config/waybar/style.css"
  local target rel src_file

  for link in "$config_link" "$style_link"; do
    [[ -L "$link" ]] || continue
    target="$(readlink -f "$link" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    [[ "$target" == "$HOME/.config/waybar/"* ]] || continue
    rel="${target#$HOME/}"
    src_file="$SRC/${rel#.config/}"
    if [[ -f "$src_file" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: enforce active waybar target $rel from repo copy"
      else
        sync_file_strict "$src_file" "$target"
      fi
    fi
  done
}

while IFS= read -r -d '' file; do
  rel="${file#$SRC/}"
  if ! backup_path "$rel"; then
    warn "Backup failed for $rel"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  if ! apply_path "$rel"; then
    warn "Apply failed for $rel"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done < <(find "$SRC" -mindepth 1 -maxdepth 1 -print0)

enforce_active_waybar_targets

# user services (best-effort)
if [[ -d "$HOME/.config/systemd/user" ]]; then
  run_cmd systemctl --user daemon-reload || true
  for svc in tether-monitor.service voice-interrupt-daemon.service crypto-tui.service voice-handsfree-daemon.service; do
    if [[ -f "$HOME/.config/systemd/user/$svc" ]]; then
      run_cmd systemctl --user enable --now "$svc" || true
    fi
  done
fi

# Ensure executables
if [[ "$DRY_RUN" -eq 0 ]]; then
  find "$HOME/.config/hypr/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  find "$HOME/waybar-scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  find "$HOME/waybar-scripts" -type f -name '*.py' -exec chmod +x {} + 2>/dev/null || true
  find "$HOME/.config/dotfiles" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  warn "Dotfiles applied with $FAIL_COUNT item failures. Backup: $BACKUP_DIR"
else
  log "Dotfiles applied successfully. Backup: $BACKUP_DIR"
fi
