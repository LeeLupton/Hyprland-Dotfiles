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
print_status "Preferred GPU:" "${DOTFILES_GPU_VENDOR:-unknown}"
print_status "Default iface:" "${DOTFILES_DEFAULT_IFACE:-unknown}"
print_status "Voice source:" "${DOTFILES_VOICE_SOURCE:-unknown}"

if command -v lspci >/dev/null 2>&1; then
  gpu_lines="$(lspci | grep -Ei 'vga|3d|display' || true)"
  if [[ -n "${gpu_lines:-}" ]]; then
    print_status "GPUs:" "$(echo "$gpu_lines" | head -n1)"
    extra_gpus="$(echo "$gpu_lines" | tail -n +2 || true)"
    if [[ -n "${extra_gpus:-}" ]]; then
      while IFS= read -r g; do
        [[ -n "$g" ]] && print_status "" "$g"
      done <<<"$extra_gpus"
    fi
  else
    print_status "GPUs:" "unknown"
  fi
fi

if command -v lsmod >/dev/null 2>&1; then
  if lsmod | grep -Eq 'nvidia|amdgpu|i915'; then
    print_status "GPU driver modules:" "$(lsmod | awk '/nvidia|amdgpu|i915/ {printf "%s ", $1}')"
  else
    print_status "GPU driver modules:" "not detected"
  fi
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  nvsmi_line="$(nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
  print_status "NVIDIA-SMI:" "${nvsmi_line:-available (no data)}"
  if nvidia-smi 2>/dev/null | grep -q "Hyprland"; then
    print_status "NVIDIA in use:" "yes (Hyprland on NVIDIA)"
  else
    print_status "NVIDIA in use:" "no Hyprland process on NVIDIA"
  fi
fi

if command -v rocm-smi >/dev/null 2>&1; then
  amd_line="$(rocm-smi --showproductname --showuse --showmemuse 2>/dev/null | rg -m1 'GPU\\[' || true)"
  print_status "ROCm-SMI:" "${amd_line:-available (no data)}"
elif command -v amd-smi >/dev/null 2>&1; then
  amd_line="$(amd-smi list --gpu 2>/dev/null | head -n1 || true)"
  print_status "AMD-SMI:" "${amd_line:-available (no data)}"
fi
