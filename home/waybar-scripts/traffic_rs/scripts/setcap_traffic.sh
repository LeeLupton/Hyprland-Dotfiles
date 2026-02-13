#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="$HOME/waybar-scripts/traffic_rs/target/debug/traffic_rs"
GUI_PATH="$HOME/waybar-scripts/traffic_rs/target/debug/traffic_gui"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "traffic_rs binary not found at $BIN_PATH"
  exit 1
fi

if [[ ! -x "$GUI_PATH" ]]; then
  echo "traffic_gui binary not found at $GUI_PATH"
  exit 1
fi

echo "Applying caps to $BIN_PATH"
sudo setcap cap_net_raw,cap_net_admin=eip "$BIN_PATH"

echo "Applying caps to $GUI_PATH"
sudo setcap cap_net_raw,cap_net_admin=eip "$GUI_PATH"

echo "Done."
