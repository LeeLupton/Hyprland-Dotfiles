#!/usr/bin/env bash
set -euo pipefail

VENV="$HOME/.config/hypr/voice/venv"
PY="$VENV/bin/python"
SCRIPT="$HOME/.config/hypr/scripts/voice_log_gui.py"

if [[ -x "$PY" ]]; then
  exec "$PY" "$SCRIPT" "$@"
fi

exec python3 "$SCRIPT" "$@"
