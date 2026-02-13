#!/bin/bash

# Launch Tether Monitor
kitty --title "Tether Monitor" --hold zsh -c "source $HOME/.gemini/antigravity/scratch/tether-peg-monitor/venv/bin/activate && python $HOME/.gemini/antigravity/scratch/tether-peg-monitor/tether_monitor.py" &

# Launch Crypto TUI
CRYPTO_DIR="$HOME/.gemini/antigravity/scratch/crypto-tui"
CRYPTO_BIN="$CRYPTO_DIR/target/release/crypto-tui"

if [ -x "$CRYPTO_BIN" ]; then
  kitty --title "Crypto TUI" --hold "$CRYPTO_BIN" &
elif [ -d "$CRYPTO_DIR" ]; then
  # Fall back to building/running if the release binary is missing.
  kitty --title "Crypto TUI" --hold zsh -lc "cd \"$CRYPTO_DIR\" && cargo run --release" &
else
  echo "Crypto TUI directory not found: $CRYPTO_DIR" >&2
fi

# Launch Crypto Flow
CRYPTO_FLOW_DIR="$HOME/crypto-flow"
if [ -d "$CRYPTO_FLOW_DIR" ]; then
  kitty --title "Crypto Flow" --hold zsh -lc "cd \"$CRYPTO_FLOW_DIR\" && cargo run --release" &
else
  echo "Crypto Flow directory not found: $CRYPTO_FLOW_DIR" >&2
fi
