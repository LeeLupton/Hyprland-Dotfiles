#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
AUTO_YES=0
SKIP_INSTALL=0
SKIP_APPLY=0
SKIP_AUTODETECT=0

log() { printf '[bootstrap] %s\n' "$*"; }
warn() { printf '[bootstrap][warn] %s\n' "$*" >&2; }
die() { printf '[bootstrap][error] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: bash ./bootstrap.sh [options]

Options:
  --yes               Run non-interactively
  --dry-run           Validate and print actions without changing system
  --skip-install      Skip dependency installation
  --skip-apply        Skip dotfiles apply step
  --skip-autodetect   Skip dynamic hardware/session patching
  -h, --help          Show this help
EOF
}

confirm_or_exit() {
  if [[ "$AUTO_YES" -eq 1 ]]; then
    return
  fi
  printf 'This will modify packages/configs on this machine. Continue? [y/N]: '
  read -r ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]] || die "Cancelled by user."
}

run_step() {
  local idx="$1" label="$2" critical="$3"
  shift 3
  log "[$idx/4] $label"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  if "$@"; then
    return 0
  fi
  if [[ "$critical" -eq 1 ]]; then
    die "Critical step failed: $label"
  fi
  warn "Non-critical step failed, continuing: $label"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) AUTO_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --skip-apply) SKIP_APPLY=1 ;;
    --skip-autodetect) SKIP_AUTODETECT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ -f /etc/arch-release ]] || die "This bootstrap targets Arch Linux only."
command -v bash >/dev/null 2>&1 || die "bash not found."

if [[ "$DRY_RUN" -eq 0 && "$SKIP_INSTALL" -eq 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required."
  sudo -v || die "sudo authentication failed."
fi

confirm_or_exit

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  run_step 1 "Installing dependencies" 1 bash "$ROOT_DIR/scripts/install_dependencies.sh" $([[ "$AUTO_YES" -eq 1 ]] && echo --yes) $([[ "$DRY_RUN" -eq 1 ]] && echo --dry-run)
else
  log "[1/4] Skipped dependency installation"
fi

if [[ "$SKIP_APPLY" -eq 0 ]]; then
  run_step 2 "Applying dotfiles" 1 bash "$ROOT_DIR/scripts/apply_dotfiles.sh" $([[ "$DRY_RUN" -eq 1 ]] && echo --dry-run)
else
  log "[2/4] Skipped dotfiles apply"
fi

if [[ "$SKIP_AUTODETECT" -eq 0 ]]; then
  run_step 3 "Auto-detecting hardware/session and patching configs" 0 bash "$ROOT_DIR/scripts/post_install_autodetect.sh" $([[ "$DRY_RUN" -eq 1 ]] && echo --dry-run)
else
  log "[3/4] Skipped autodetect"
fi

log "[4/4] Completed"
log "Reboot or re-login recommended. Run 'rice-check' after login."
