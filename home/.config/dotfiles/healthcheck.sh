#!/usr/bin/env bash
set -euo pipefail

AUTODETECT_ENV="$HOME/.config/dotfiles/autodetect.env"
[[ -f "$AUTODETECT_ENV" ]] && source "$AUTODETECT_ENV"

print_status() {
  local label="$1"
  local value="$2"
  printf "%-22s %s\n" "$label" "$value"
}

print_status "Session type:" "${XDG_SESSION_TYPE:-unknown}"
print_status "Desktop:" "${XDG_CURRENT_DESKTOP:-unknown}"
print_status "Hyprland env:" "${HYPRLAND_INSTANCE_SIGNATURE:+yes}"

if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
  print_status "hyprctl:" "ok"
else
  print_status "hyprctl:" "missing/unreachable"
fi

if pgrep -x waybar >/dev/null 2>&1; then
  print_status "waybar:" "running"
else
  print_status "waybar:" "not running"
fi

if pgrep -x xdg-desktop-portal-hyprland >/dev/null 2>&1; then
  print_status "portal-hyprland:" "running"
else
  print_status "portal-hyprland:" "not running"
fi

print_status "Display manager:" "${DOTFILES_DISPLAY_MANAGER:-unknown}"
print_status "Lock manager:" "${DOTFILES_LOCK_MANAGER:-unknown}"
print_status "Default iface:" "${DOTFILES_DEFAULT_IFACE:-unknown}"
print_status "Voice source:" "${DOTFILES_VOICE_SOURCE:-unknown}"

if command -v lspci >/dev/null 2>&1; then
  gpu_line="$(lspci | grep -Ei 'vga|3d|display' | head -n1 || true)"
  print_status "GPU:" "${gpu_line:-unknown}"
fi

if command -v lsmod >/dev/null 2>&1; then
  if lsmod | grep -Eq 'nvidia|amdgpu|i915'; then
    print_status "GPU driver module:" "$(lsmod | awk '/nvidia|amdgpu|i915/ {print $1; exit}')"
  else
    print_status "GPU driver module:" "not detected"
  fi
fi
