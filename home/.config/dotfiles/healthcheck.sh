#!/usr/bin/env bash
set -euo pipefail

AUTODETECT_ENV="$HOME/.config/dotfiles/autodetect.env"
[[ -f "$AUTODETECT_ENV" ]] && source "$AUTODETECT_ENV"

ANIMATE=1
PLAIN=0
SHOW_RICEFETCH=1
ONCE=0
REFRESH_SECS=0.10
GIF_PID=""
GIF_PATH_PRIMARY="$HOME/dot-files/assets/mcmoney.gif"
GIF_PATH_FALLBACK="/home/lee/Pictures/mcmoney.gif"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-anim) ANIMATE=0 ;;
    --anim) ANIMATE=1 ;;
    --plain) PLAIN=1 ;;
    --no-fastfetch|--no-ricefetch) SHOW_RICEFETCH=0 ;;
    --once) ONCE=1 ;;
    --refresh=*) REFRESH_SECS="${1#*=}" ;;
  esac
  shift || true
done

resolve_gif_path() {
  if [[ -f "$GIF_PATH_PRIMARY" ]]; then
    echo "$GIF_PATH_PRIMARY"
    return
  fi
  if [[ -f "$GIF_PATH_FALLBACK" ]]; then
    echo "$GIF_PATH_FALLBACK"
    return
  fi
  echo ""
}

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

# shared state populated by gather_data
session_type="unknown"
desktop="unknown"
hypr_env="no"
hyprctl_state="missing/unreachable"
waybar_state="not running"
portal_state="not running"

os_name="unknown"
host="unknown"
kernel="unknown"
uptime_human="unknown"
shell_name="unknown"
wm_name="unknown"
term_name="unknown"
cpu_model="unknown"
mem_line="unknown"
pkg_count="unknown"

gpu_lines=""
gpu_modules="not detected"
nvidia_summary="not available"
nvidia_usage="unknown"
amd_summary=""

npu_pci=""
npu_mods="none"
accel_nodes="none"

gather_data() {
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

  os_name="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
  [[ -n "$os_name" ]] || os_name="$(uname -s)"
  kernel="$(uname -r 2>/dev/null || echo unknown)"
  host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  shell_name="${SHELL##*/}"
  wm_name="${XDG_CURRENT_DESKTOP:-unknown}"
  term_name="${TERM:-unknown}"
  cpu_model="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [[ -n "$cpu_model" ]] || cpu_model="unknown"

  if [[ -r /proc/uptime ]]; then
    local up
    up="$(cut -d' ' -f1 /proc/uptime)"
    uptime_human="$(awk -v u="$up" 'BEGIN{d=int(u/86400); h=int((u%86400)/3600); m=int((u%3600)/60); if(d>0) printf "%dd %dh %dm",d,h,m; else printf "%dh %dm",h,m}')"
  else
    uptime_human="unknown"
  fi

  mem_line="$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {if(t>0){u=t-a; printf "%.1f/%.1f GiB", u/1048576, t/1048576} else print "unknown"}' /proc/meminfo 2>/dev/null)"

  if command -v pacman >/dev/null 2>&1; then
    pkg_count="$(pacman -Qq 2>/dev/null | wc -l | tr -d ' ')"
  else
    pkg_count="unknown"
  fi

  gpu_lines=""
  if command -v lspci >/dev/null 2>&1; then
    gpu_lines="$(lspci | grep -Ei 'vga|3d|display' || true)"
  fi

  gpu_modules="not detected"
  if command -v lsmod >/dev/null 2>&1; then
    local gm
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

  npu_pci=""
  if command -v lspci >/dev/null 2>&1; then
    npu_pci="$(lspci -nn 2>/dev/null | grep -Ei 'neural|npu|vpu|gaussian.*neural|processing accelerators|xdna' || true)"
  fi

  npu_mods="none"
  if command -v lsmod >/dev/null 2>&1; then
    local nm
    nm="$(lsmod | awk '/^intel_vpu|^amdxdna|^qaic|^hailo_pci/ {printf "%s ", $1}')"
    [[ -n "$nm" ]] && npu_mods="$nm"
  fi

  accel_nodes="none"
  if [[ -d /dev/accel ]]; then
    local an
    an="$(ls -1 /dev/accel 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "$an" ]] && accel_nodes="$an"
  fi
}

render_ricefetch_block() {
  print_sep
  printf "%b%s%b\n" "$C4" "RICEFETCH CORE" "$C0"
  print_kv "OS:" "$os_name"
  print_kv "Host:" "$host"
  print_kv "Kernel:" "$kernel"
  print_kv "Uptime:" "$uptime_human"
  print_kv "Shell:" "$shell_name"
  print_kv "WM/DE:" "$wm_name"
  print_kv "Terminal:" "$term_name"
  print_kv "CPU:" "$cpu_model"
  print_kv "Memory:" "$mem_line"
  print_kv "Packages:" "$pkg_count"
}

render_body() {
  if [[ "$SHOW_RICEFETCH" -eq 1 ]]; then
    render_ricefetch_block
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
    local first_gpu extra_gpu
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
    local first_npu extra_npu
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
}

render_gif_block() {
  local gif_path="$1"
  local mode="${2:-static}"
  local place_arg="${3:-}"
  local icat_engine="builtin"
  local tty_out="/dev/tty"
  [[ -n "$gif_path" ]] || return 0
  [[ -t 1 ]] || return 0
  [[ -w "$tty_out" ]] || tty_out="/proc/self/fd/1"

  if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
    icat_engine="magick"
  fi

  if command -v kitten >/dev/null 2>&1 && [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
    # Kitty ships the image protocol client, so this works without extra installs.
    if [[ "$mode" == "tui" ]]; then
      [[ -n "$place_arg" ]] || return 1
      kitten icat --clear --silent >"$tty_out" 2>/dev/null || true
      kitten icat --silent --stdin=no --engine="$icat_engine" --z-index=0 --place "$place_arg" --loop -1 "$gif_path" >"$tty_out" 2>/dev/null &
      GIF_PID="$!"
      return 0
    elif kitten icat --silent --stdin=no --engine="$icat_engine" "$gif_path" >"$tty_out" 2>/dev/null; then
      return 0
    fi
  fi

  if command -v chafa >/dev/null 2>&1; then
    # Render GIF content in-terminal as a native CLI block.
    chafa --size=42x12 --animate=off "$gif_path" 2>/dev/null || {
      print_kv "GIF:" "failed to render $gif_path"
    }
    return 0
  fi

  print_kv "GIF:" "$gif_path (install 'chafa' for inline rendering)"
}

render_static() {
  local gif_path
  gif_path="$(resolve_gif_path)"
  gather_data
  printf "%b%s%b\n" "$C1" "RICE-CHECK :: RICEFETCH" "$C0"
  if [[ "$ANIMATE" -eq 1 ]] && [[ -t 1 ]]; then
    printf "%b%s%b\n" "$C1" "RICE-CHECK GIF CORE" "$C0"
    render_gif_block "$gif_path"
  fi
  render_body
}

render_tui() {
  local gif_path
  local tick=0
  local body_row=3
  local cols lines left_width gif_left gif_top gif_w gif_h gif_place
  local row
  gif_path="$(resolve_gif_path)"
  cols="$(tput cols 2>/dev/null || echo 120)"
  lines="$(tput lines 2>/dev/null || echo 40)"

  left_width=62
  if (( cols < 110 )); then
    left_width=56
  fi
  gif_left=$(( left_width + 2 ))
  gif_top=2
  gif_w=$(( cols - gif_left - 1 ))
  gif_h=$(( lines - 4 ))
  if (( gif_w < 18 || gif_h < 8 )); then
    gif_place=""
  else
    gif_place="${gif_w}x${gif_h}@${gif_left}x${gif_top}"
  fi

  tput civis 2>/dev/null || true
  tput smcup 2>/dev/null || true
  trap '[[ -n "$GIF_PID" ]] && kill "$GIF_PID" >/dev/null 2>&1 || true; kitten icat --clear --silent >/dev/null 2>&1 || true; tput rmcup 2>/dev/null || true; tput cnorm 2>/dev/null || true; printf "\n"' EXIT INT TERM

  gather_data
  printf "\033[H\033[J"
  printf "%b%s%b\n" "$C1" "RICE-CHECK :: RICEFETCH" "$C0"
  printf "%b%s%b\n" "$C1" "RICE-CHECK GIF CORE  (q to quit) | left metrics / right gif" "$C0"
  printf "%b%s%b\n" "$C2" "$(printf '%*s' "$left_width" '' | tr ' ' '-')" "$C0"
  if [[ "$ANIMATE" -eq 1 ]] && [[ -n "$gif_place" ]]; then
    render_gif_block "$gif_path" "tui" "$gif_place"
  elif [[ "$ANIMATE" -eq 1 ]]; then
    printf "%b%s%b\n" "$C3" "terminal too small for GIF pane; enlarge window for animation" "$C0"
  fi
  printf "\033[%d;1H" "$body_row"
  render_body

  while true; do
    # refresh metrics every ~1s without re-sending the GIF
    if (( tick % 10 == 0 )); then
      gather_data
      for ((row = body_row; row <= lines; row++)); do
        printf "\033[%d;1H%-*s" "$row" "$left_width" ""
      done
      printf "\033[%d;1H" "$body_row"
      render_body
    fi

    # non-blocking key read
    if read -rsn1 -t "$REFRESH_SECS" key; then
      case "$key" in
        q|Q) break ;;
      esac
    fi

    tick=$((tick + 1))
  done
}

# choose mode
if [[ "$ONCE" -eq 1 || ! -t 1 || "$ANIMATE" -eq 0 ]]; then
  render_static
else
  render_tui
fi
