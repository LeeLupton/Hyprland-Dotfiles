#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="$ROOT_DIR/manifests"
DRY_RUN=0
AUTO_YES=0

log() { printf '[deps] %s\n' "$*"; }
warn() { printf '[deps][warn] %s\n' "$*" >&2; }
die() { printf '[deps][error] %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) AUTO_YES=1 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

install_pkg_list() {
  local manager="$1"; shift
  local -a pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0
  if [[ "$manager" == "pacman" ]]; then
    if ! run_cmd sudo pacman -S --needed --noconfirm "${pkgs[@]}"; then
      warn "Bulk pacman install failed, retrying package-by-package."
      local p
      for p in "${pkgs[@]}"; do
        run_cmd sudo pacman -S --needed --noconfirm "$p" || warn "Failed to install: $p"
      done
    fi
  elif [[ "$manager" == "yay" ]]; then
    if ! run_cmd yay -S --needed --noconfirm "${pkgs[@]}"; then
      warn "Bulk yay install failed, retrying package-by-package."
      local p
      for p in "${pkgs[@]}"; do
        run_cmd yay -S --needed --noconfirm "$p" || warn "Failed AUR install: $p"
      done
    fi
  fi
}

[[ -f "$MANIFESTS/pacman-explicit.txt" ]] || die "Missing manifest: pacman-explicit.txt"
command -v pacman >/dev/null 2>&1 || die "pacman not found"

if [[ "$DRY_RUN" -eq 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  sudo -v || die "sudo authentication failed"
fi

run_cmd sudo pacman -Syu --noconfirm
install_pkg_list pacman git base-devel curl wget unzip tar stow python python-pip pipx nodejs npm

# Split official vs AUR (aur list may be empty)
OFFICIAL_TMP="$(mktemp)"
if [[ -s "$MANIFESTS/aur-explicit.txt" ]]; then
  comm -23 <(sort "$MANIFESTS/pacman-explicit.txt") <(sort "$MANIFESTS/aur-explicit.txt") > "$OFFICIAL_TMP"
else
  cp "$MANIFESTS/pacman-explicit.txt" "$OFFICIAL_TMP"
fi

if [[ -s "$OFFICIAL_TMP" ]]; then
  mapfile -t official_pkgs < "$OFFICIAL_TMP"
  install_pkg_list pacman "${official_pkgs[@]}"
fi

if [[ -s "$MANIFESTS/aur-explicit.txt" ]]; then
  if ! command -v yay >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    run_cmd git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      (cd "$tmpdir/yay" && makepkg -si --noconfirm) || warn "Failed to build yay"
    fi
    rm -rf "$tmpdir"
  fi
  if command -v yay >/dev/null 2>&1; then
    mapfile -t aur_pkgs < <(sort -u "$MANIFESTS/aur-explicit.txt")
    install_pkg_list yay "${aur_pkgs[@]}"
  else
    warn "Skipping AUR packages because yay is unavailable."
  fi
fi

# pipx packages
if [[ -s "$MANIFESTS/pipx.txt" ]]; then
  while read -r pkg version; do
    [[ -z "${pkg:-}" ]] && continue
    if command -v pipx >/dev/null 2>&1; then
      run_cmd pipx install --force "$pkg" || warn "pipx install failed: $pkg"
    else
      warn "pipx not found, skipping: $pkg"
    fi
  done < "$MANIFESTS/pipx.txt"
fi

# npm globals
if [[ -s "$MANIFESTS/npm-global-packages.txt" ]]; then
  if command -v npm >/dev/null 2>&1; then
    mapfile -t npm_pkgs < <(sort -u "$MANIFESTS/npm-global-packages.txt")
    if ! run_cmd npm install -g "${npm_pkgs[@]}"; then
      warn "Bulk npm global install failed, retrying one-by-one."
      for p in "${npm_pkgs[@]}"; do
        run_cmd npm install -g "$p" || warn "npm global install failed: $p"
      done
    fi
  else
    warn "npm not found, skipping npm globals"
  fi
fi

# Voice assistant virtualenv requirements (optional)
if [[ -s "$MANIFESTS/voice-venv-requirements.txt" ]]; then
  if command -v python >/dev/null 2>&1; then
    run_cmd python -m venv "$HOME/.config/hypr/voice/venv"
    run_cmd "$HOME/.config/hypr/voice/venv/bin/pip" install -U pip
    run_cmd "$HOME/.config/hypr/voice/venv/bin/pip" install -r "$MANIFESTS/voice-venv-requirements.txt" || warn "voice venv requirements install failed"
  else
    warn "python not found, skipping voice venv"
  fi
fi

rm -f "$OFFICIAL_TMP"
log "Dependency step completed."
