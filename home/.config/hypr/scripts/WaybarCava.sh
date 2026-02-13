#!/usr/bin/env bash
# WaybarCava.sh — Persistent Daemon Wrapper
# Robustly handles Cava restarts without crashing Waybar.

set -u

# Mode: output (default) or input
MODE="${1:-output}"
SAFE_MODE=$(echo "$MODE" | sed 's/[^a-zA-Z0-9]//g')

# Init vars for cleanup trap
config_file=""
pidfile=""

# Ensure cava exists
if ! command -v cava >/dev/null 2>&1; then
  echo "cava missing"
  while true; do sleep 60; done
fi

# 0..7 → ▁▂▃▄▅▆▇█
bar="▁▂▃▄▅▆▇█"
dict="s/;//g"
bar_length=${#bar}
for ((i = 0; i < bar_length; i++)); do
  dict+=";s/$i/${bar:$i:1}/g"
done

# Single-instance guard per mode
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
pidfile="$RUNTIME_DIR/waybar-cava-${SAFE_MODE}.pid"

# Cleanup function
cleanup() {
    rm -f "$config_file" "$pidfile"
    # Kill all child processes (the running cava instance)
    pkill -P $$ 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM

# Check existing instance
if [[ -f "$pidfile" ]]; then
  oldpid="$(cat "$pidfile" || true)"
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    # Already running, exit silently to prevent duplicates
    exit 0
  fi
fi
printf '%d' $$ >"$pidfile"

# Generate Config
config_file="$(mktemp "$RUNTIME_DIR/waybar-cava-${SAFE_MODE}.XXXXXX.conf")"

# Loop forever to restart cava if it crashes
while true; do
    # Determine Source (check every time in case PA restarted and source ID changed)
    if [[ "$MODE" == "input" ]]; then
        if command -v pactl >/dev/null 2>&1; then
            SOURCE=$(pactl get-default-source 2>/dev/null || echo "auto")
        else
            SOURCE="auto"
        fi
    else
        SOURCE="auto"
    fi

    # Write config
    cat >"$config_file" <<EOF
[general]
framerate = 30
bars = 10

[input]
method = pulse
source = $SOURCE

[output]
method = raw
raw_target = /dev/stdout
data_format = ascii
ascii_max_range = 7
EOF

    # Run Cava
    # We pipe to sed. If cava dies, sed closes? 
    # Actually, if cava dies, the pipe closes.
    cava -p "$config_file" 2>/dev/null | sed -u "$dict"
    
    # If we got here, cava exited.
    # Sleep briefly to prevent CPU spinning if hard failure
    sleep 1
done
