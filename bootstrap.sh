#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /etc/arch-release ]]; then
  echo "This bootstrap targets Arch Linux only." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/3] Installing dependencies"
bash "$ROOT_DIR/scripts/install_dependencies.sh"

echo "[2/3] Applying dotfiles"
bash "$ROOT_DIR/scripts/apply_dotfiles.sh"

echo "[3/3] Done"
echo "Reboot or re-login recommended."
