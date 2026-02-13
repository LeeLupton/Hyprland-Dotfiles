#!/usr/bin/env bash
set -euo pipefail

AUTODETECT_ENV="$HOME/.config/dotfiles/autodetect.env"
[[ -f "$AUTODETECT_ENV" ]] && source "$AUTODETECT_ENV"

ANIMATE=1
PLAIN=0
SHOW_FASTFETCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-anim) ANIMATE=0 ;;
    --anim) ANIMATE=1 ;;
    --plain) PLAIN=1 ;;
    --no-fastfetch) SHOW_FASTFETCH=0 ;;
  esac
  shift || true
done

if [[ "$PLAIN" -eq 1 ]]; then
  C0=""; C1=""; C2=""; C3=""; C4=""; C5=""
else
  C0="\033[0m"
  C1="\033[1;38;5;39m"
  C2="\033[1;38;5;45m"
  C3="\033[1;38;5;214m"
  C4="\033[1;38;5;120m"
  C5="\033[38;5;250m"
fi

print_kv() {
  local k="$1"
  local v="$2"
  printf "%b%-24s%b %s\n" "$C2" "$k" "$C0" "$v"
}

print_sep() {
  printf "%b%s%b\n" "$C5" "------------------------------------------------------------" "$C0"
}

animate_cube() {
  [[ -t 1 ]] || return 0
  [[ "$ANIMATE" -eq 1 ]] || return 0

  local frames=(
$'      +------+\n     /     /|\n    +------+ |\n    |      | +\n    |      |/\n    +------+'
$'      /\\\n     /  \\____\n    /  /\\   /|\n   +--+--+-+ |\n   |  |  | |/\n   +--+--+-+'
$'    +------+ \n    |\\     | \\\n    | +----+--+\n    | |    |  |\n    +-|----+  |\n      +-------+'
$'       ____\n   |\\   \\   \\\n   | +---+---+\n   | |   |   |\n   +-|---+  /\n     +-----+'
  )

  local i
  printf "%b%s%b\n" "$C1" "RICE-CHECK 3D CORE" "$C0"
  for i in "${frames[@]}"; do
    printf "\033[2K\r"
    printf "%b%b%b\n" "$C3" "$i" "$C0"
    sleep 0.06
    printf "\033[7A"
  done
  printf "\033[7B"
}

# System/session fast probes
session_type="${XDG_SESSION_TYPE:-unknown}"
desktop="${XDG_CURRENT_DESKTOP:-unknown}"
hypr_env="${HYPRLAND_INSTANCE_SIGNATURE:+yes}"
[[ -n "$hypr_env" ]] || hypr_env="no"

hyprctl_state="missing/unreachable"
if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
  hyprctl_state="ok"
fi

waybar_state="not running"
pgrep -x waybar >/dev/null 2>&1 && waybar_state="running"

portal_state="not running"
pgrep -x xdg-desktop-portal-hyprland >/dev/null 2>&1 && portal_state="running"

# GPU probes
gpu_lines=""
if command -v lspci >/dev/null 2>&1; then
  gpu_lines="$(lspci | grep -Ei 'vga|3d|display' || true)"
fi

gpu_modules="not detected"
if command -v lsmod >/dev/null 2>&1; then
  gm="$(lsmod | awk '/nvidia|amdgpu|i915/ {printf "%s ", $1}')"
  [[ -n "$gm" ]] && gpu_modules="$gm"
fi

nvidia_summary="not available"
nvidia_usage="unknown"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia_summary="$(nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
  [[ -n "$nvidia_summary" ]] || nvidia_summary="available (no data)"
  if nvidia-smi 2>/dev/null | grep -q "Hyprland"; then
    nvidia_usage="yes (Hyprland on NVIDIA)"
  else
    nvidia_usage="no Hyprland process on NVIDIA"
  fi
fi

amd_summary=""
if command -v rocm-smi >/dev/null 2>&1; then
  amd_summary="$(rocm-smi --showproductname --showuse --showmemuse 2>/dev/null | rg -m1 'GPU\[' || true)"
elif command -v amd-smi >/dev/null 2>&1; then
  amd_summary="$(amd-smi list --gpu 2>/dev/null | head -n1 || true)"
fi

# NPU probes
npu_pci=""
if command -v lspci >/dev/null 2>&1; then
  npu_pci="$(lspci -nn 2>/dev/null | grep -Ei 'neural|npu|vpu|gaussian.*neural|processing accelerators|xdna' || true)"
fi

npu_mods="none"
if command -v lsmod >/dev/null 2>&1; then
  nm="$(lsmod | awk '/^intel_vpu|^amdxdna|^qaic|^hailo_pci/ {printf "%s ", $1}')"
  [[ -n "$nm" ]] && npu_mods="$nm"
fi

accel_nodes="none"
if [[ -d /dev/accel ]]; then
  an="$(ls -1 /dev/accel 2>/dev/null | tr '\n' ' ' || true)"
  [[ -n "$an" ]] && accel_nodes="$an"
fi

# Header and optional visual
printf "%b%s%b\n" "$C1" "RICE-CHECK :: SUPERFETCH" "$C0"
animate_cube

if [[ "$SHOW_FASTFETCH" -eq 1 ]] && command -v fastfetch >/dev/null 2>&1; then
  fastfetch --logo none 2>/dev/null || true
  print_sep
fi

printf "%b%s%b\n" "$C4" "SESSION" "$C0"
print_kv "Session type:" "$session_type"
print_kv "Desktop:" "$desktop"
print_kv "Hyprland env:" "$hypr_env"
print_kv "hyprctl:" "$hyprctl_state"
print_kv "waybar:" "$waybar_state"
print_kv "portal-hyprland:" "$portal_state"
print_kv "Display manager:" "${DOTFILES_DISPLAY_MANAGER:-unknown}"
print_kv "Lock manager:" "${DOTFILES_LOCK_MANAGER:-unknown}"
print_kv "Default iface:" "${DOTFILES_DEFAULT_IFACE:-unknown}"
print_kv "Voice source:" "${DOTFILES_VOICE_SOURCE:-unknown}"

print_sep
printf "%b%s%b\n" "$C4" "GPU" "$C0"
print_kv "Preferred GPU:" "${DOTFILES_GPU_VENDOR:-unknown}"
if [[ -n "$gpu_lines" ]]; then
  first_gpu="$(echo "$gpu_lines" | head -n1)"
  print_kv "GPU PCI:" "$first_gpu"
  extra_gpu="$(echo "$gpu_lines" | tail -n +2 || true)"
  if [[ -n "$extra_gpu" ]]; then
    while IFS= read -r g; do
      [[ -n "$g" ]] && print_kv "" "$g"
    done <<<"$extra_gpu"
  fi
else
  print_kv "GPU PCI:" "unknown"
fi
print_kv "GPU driver modules:" "$gpu_modules"
print_kv "NVIDIA-SMI:" "$nvidia_summary"
print_kv "NVIDIA in use:" "$nvidia_usage"
[[ -n "$amd_summary" ]] && print_kv "AMD-SMI:" "$amd_summary"

print_sep
printf "%b%s%b\n" "$C4" "NPU" "$C0"
print_kv "NPU vendor:" "${DOTFILES_NPU_VENDOR:-unknown}"
print_kv "NPU driver:" "${DOTFILES_NPU_DRIVER:-unknown}"
print_kv "NPU device:" "${DOTFILES_NPU_DEVICE:-unknown}"
print_kv "NPU runtime tools:" "${DOTFILES_NPU_RUNTIME:-unknown}"
print_kv "NPU ready:" "${DOTFILES_NPU_READY:-unknown}"

if [[ -n "$npu_pci" ]]; then
  first_npu="$(echo "$npu_pci" | head -n1)"
  print_kv "NPU PCI:" "$first_npu"
  extra_npu="$(echo "$npu_pci" | tail -n +2 || true)"
  if [[ -n "$extra_npu" ]]; then
    while IFS= read -r n; do
      [[ -n "$n" ]] && print_kv "" "$n"
    done <<<"$extra_npu"
  fi
else
  print_kv "NPU PCI:" "none detected"
fi

print_kv "NPU modules loaded:" "$npu_mods"
print_kv "/dev/accel nodes:" "$accel_nodes"

if [[ "${DOTFILES_NPU_READY:-no}" != "yes" ]]; then
  print_sep
  printf "%b%s%b\n" "$C3" "NPU guidance: load vendor driver/firmware, then run rice-autodetect" "$C0"
fi
