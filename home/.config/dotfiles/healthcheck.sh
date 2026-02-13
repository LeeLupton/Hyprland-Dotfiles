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

# live telemetry state
cpu_prev_total=0
cpu_prev_idle=0
cpu_usage_pct=0
cpu_freq_mhz=0
cpu_voltage_v="n/a"
mem_usage_pct=0
gpu_usage_pct=0
gpu_mem_pct=0
gpu_temp_c="n/a"
gpu_power_w="n/a"
gpu_clock_mhz="n/a"
net_rx_rate_bps=0
net_tx_rate_bps=0
net_prev_rx=0
net_prev_tx=0
hist_cpu=""
hist_mem=""
hist_gpu=""
hist_net=""
HIST_LEN=28

append_hist() {
  local current="$1"
  local value="$2"
  local max_len="$3"
  current="${current} ${value}"
  current="$(echo "$current" | awk '{$1=$1; print}')"
  local count
  count="$(wc -w <<<"$current" | tr -d ' ')"
  while (( count > max_len )); do
    current="${current#* }"
    count=$((count - 1))
  done
  echo "$current"
}

hist_graph() {
  local data="$1"
  local out=""
  local v idx
  # 10-level ASCII ramp for terminal-safe sparkline.
  local ramp=" .:-=+*#%@"
  for v in $data; do
    idx=$(( (v * 9 + 50) / 100 ))
    (( idx < 0 )) && idx=0
    (( idx > 9 )) && idx=9
    out="${out}${ramp:idx:1}"
  done
  echo "$out"
}

percent_bar() {
  local pct="$1"
  local width="${2:-18}"
  local filled
  local out=""
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  filled=$(( (pct * width + 50) / 100 ))
  out="$(printf "%${filled}s" "" | tr ' ' '#')"
  out="${out}$(printf "%$((width - filled))s" "" | tr ' ' '.')"
  echo "$out"
}

format_bps() {
  local bps="$1"
  if (( bps >= 1000000000 )); then
    awk -v v="$bps" 'BEGIN{printf "%.2f Gbps", v/1000000000}'
  elif (( bps >= 1000000 )); then
    awk -v v="$bps" 'BEGIN{printf "%.2f Mbps", v/1000000}'
  elif (( bps >= 1000 )); then
    awk -v v="$bps" 'BEGIN{printf "%.1f Kbps", v/1000}'
  else
    printf "%d bps" "$bps"
  fi
}

detect_cpu_voltage() {
  local p raw
  for p in /sys/class/hwmon/hwmon*/in*_input; do
    [[ -r "$p" ]] || continue
    raw="$(cat "$p" 2>/dev/null || true)"
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    if (( raw >= 300 && raw <= 3000 )); then
      awk -v mv="$raw" 'BEGIN{printf "%.3fV", mv/1000}'
      return
    fi
  done
  echo "n/a"
}

sample_live_metrics() {
  local iface now_rx now_tx
  local prev_total prev_idle total idle d_total d_idle usage
  local net_bps total_kb avail_kb

  if read -r _ _ _ _ user nice sys idle iowait irq softirq steal _ < /proc/stat; then
    total=$((user + nice + sys + idle + iowait + irq + softirq + steal))
    idle=$((idle + iowait))
    prev_total="$cpu_prev_total"
    prev_idle="$cpu_prev_idle"
    cpu_prev_total="$total"
    cpu_prev_idle="$idle"
    if (( prev_total > 0 && total > prev_total )); then
      d_total=$((total - prev_total))
      d_idle=$((idle - prev_idle))
      usage=$(( (100 * (d_total - d_idle)) / d_total ))
      (( usage < 0 )) && usage=0
      (( usage > 100 )) && usage=100
      cpu_usage_pct="$usage"
    fi
  fi

  if [[ -r /proc/meminfo ]]; then
    mem_usage_pct="$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {if(t>0){u=t-a; printf "%d", (u*100)/t} else print 0}' /proc/meminfo)"
  fi

  if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
    cpu_freq_mhz="$(awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)"
  else
    cpu_freq_mhz="$(awk -F: '/cpu MHz/ {sum+=$2; n++} END {if(n>0) printf "%d", sum/n; else print 0}' /proc/cpuinfo 2>/dev/null)"
  fi
  cpu_voltage_v="$(detect_cpu_voltage)"

  if command -v nvidia-smi >/dev/null 2>&1; then
    local nv
    nv="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.current.graphics --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    if [[ -n "$nv" ]]; then
      gpu_usage_pct="$(echo "$nv" | awk -F, '{gsub(/ /,"",$1); print int($1)}')"
      local mem_used mem_total
      mem_used="$(echo "$nv" | awk -F, '{gsub(/ /,"",$2); print int($2)}')"
      mem_total="$(echo "$nv" | awk -F, '{gsub(/ /,"",$3); print int($3)}')"
      if (( mem_total > 0 )); then
        gpu_mem_pct=$(( (mem_used * 100) / mem_total ))
      fi
      gpu_temp_c="$(echo "$nv" | awk -F, '{gsub(/ /,"",$4); print int($4) "C"}')"
      gpu_power_w="$(echo "$nv" | awk -F, '{gsub(/ /,"",$5); printf "%.1fW", $5}')"
      gpu_clock_mhz="$(echo "$nv" | awk -F, '{gsub(/ /,"",$6); print int($6) "MHz"}')"
    fi
  elif command -v rocm-smi >/dev/null 2>&1; then
    local util
    util="$(rocm-smi --showuse 2>/dev/null | awk -F': ' '/GPU use/ {gsub(/%/, "", $2); print int($2); exit}' || true)"
    [[ -n "$util" ]] && gpu_usage_pct="$util"
    gpu_mem_pct=0
    gpu_temp_c="$(rocm-smi --showtemp 2>/dev/null | awk -F': ' '/Temperature/ {print $2; exit}' || echo n/a)"
    gpu_power_w="$(rocm-smi --showpower 2>/dev/null | awk -F': ' '/Average Graphics Package Power/ {print $2; exit}' || echo n/a)"
    gpu_clock_mhz="$(rocm-smi --showclk 2>/dev/null | awk -F': ' '/sclk clock level/ {print $2; exit}' || echo n/a)"
  else
    gpu_usage_pct=0
    gpu_mem_pct=0
    gpu_temp_c="n/a"
    gpu_power_w="n/a"
    gpu_clock_mhz="n/a"
  fi

  iface="${DOTFILES_DEFAULT_IFACE:-}"
  [[ -z "$iface" || "$iface" == "unknown" ]] && iface="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
  if [[ -n "$iface" && -r "/sys/class/net/$iface/statistics/rx_bytes" && -r "/sys/class/net/$iface/statistics/tx_bytes" ]]; then
    now_rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)"
    now_tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)"
    if (( net_prev_rx > 0 )) && (( now_rx >= net_prev_rx )); then
      net_rx_rate_bps=$(( (now_rx - net_prev_rx) * 8 ))
    else
      net_rx_rate_bps=0
    fi
    if (( net_prev_tx > 0 )) && (( now_tx >= net_prev_tx )); then
      net_tx_rate_bps=$(( (now_tx - net_prev_tx) * 8 ))
    else
      net_tx_rate_bps=0
    fi
    net_prev_rx="$now_rx"
    net_prev_tx="$now_tx"
  else
    net_rx_rate_bps=0
    net_tx_rate_bps=0
  fi

  net_bps=$((net_rx_rate_bps + net_tx_rate_bps))
  # Normalize to 1Gbps scale for graphing.
  if (( net_bps > 1000000000 )); then
    hist_net="$(append_hist "$hist_net" 100 "$HIST_LEN")"
  else
    hist_net="$(append_hist "$hist_net" "$(( (net_bps * 100) / 1000000000 ))" "$HIST_LEN")"
  fi
  hist_cpu="$(append_hist "$hist_cpu" "$cpu_usage_pct" "$HIST_LEN")"
  hist_mem="$(append_hist "$hist_mem" "$mem_usage_pct" "$HIST_LEN")"
  hist_gpu="$(append_hist "$hist_gpu" "$gpu_usage_pct" "$HIST_LEN")"
}

prime_live_metrics() {
  # Take two close samples so delta-based metrics (CPU/net) have real values.
  sample_live_metrics
  sleep 0.12
  sample_live_metrics
}

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

  print_sep
  printf "%b%s%b\n" "$C4" "LIVE TELEMETRY" "$C0"
  print_kv "CPU load:" "$(printf "[%s] %3d%%  %s  %s" "$(percent_bar "$cpu_usage_pct")" "$cpu_usage_pct" "${cpu_freq_mhz}MHz" "$cpu_voltage_v")"
  print_kv "Memory load:" "$(printf "[%s] %3d%%" "$(percent_bar "$mem_usage_pct")" "$mem_usage_pct")"
  print_kv "GPU load:" "$(printf "[%s] %3d%%  VRAM:%3d%%  %s  %s  %s" "$(percent_bar "$gpu_usage_pct")" "$gpu_usage_pct" "$gpu_mem_pct" "$gpu_temp_c" "$gpu_power_w" "$gpu_clock_mhz")"
  print_kv "Network:" "RX $(format_bps "$net_rx_rate_bps") | TX $(format_bps "$net_tx_rate_bps")"
  print_kv "CPU graph:" "$(hist_graph "$hist_cpu")"
  print_kv "MEM graph:" "$(hist_graph "$hist_mem")"
  print_kv "GPU graph:" "$(hist_graph "$hist_gpu")"
  print_kv "NET graph:" "$(hist_graph "$hist_net")"
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
  prime_live_metrics
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
  prime_live_metrics
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
      sample_live_metrics
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
