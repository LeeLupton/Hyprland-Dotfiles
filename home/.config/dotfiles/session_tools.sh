#!/usr/bin/env bash

rice-check() {
  if [[ -x "$HOME/.config/dotfiles/healthcheck.sh" ]]; then
    bash "$HOME/.config/dotfiles/healthcheck.sh"
  else
    echo "healthcheck script missing: ~/.config/dotfiles/healthcheck.sh"
    return 1
  fi
}

rice-restart() {
  local target="${1:-stack}"
  case "$target" in
    waybar)
      if ! command -v waybar >/dev/null 2>&1; then
        echo "waybar not found"
        return 1
      fi
      pkill -x waybar >/dev/null 2>&1 || true
      nohup waybar >/dev/null 2>&1 &
      ;;
    portal)
      pkill -x xdg-desktop-portal-hyprland >/dev/null 2>&1 || true
      pkill -x xdg-desktop-portal >/dev/null 2>&1 || true
      if command -v xdg-desktop-portal-hyprland >/dev/null 2>&1; then
        nohup xdg-desktop-portal-hyprland >/dev/null 2>&1 &
      elif [[ -x /usr/lib/xdg-desktop-portal-hyprland ]]; then
        nohup /usr/lib/xdg-desktop-portal-hyprland >/dev/null 2>&1 &
      fi
      if command -v xdg-desktop-portal >/dev/null 2>&1; then
        nohup xdg-desktop-portal >/dev/null 2>&1 &
      elif [[ -x /usr/lib/xdg-desktop-portal ]]; then
        nohup /usr/lib/xdg-desktop-portal >/dev/null 2>&1 &
      fi
      ;;
    hypr)
      if command -v hyprctl >/dev/null 2>&1 && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        hyprctl reload
      else
        echo "hyprctl unavailable or not in a Hyprland session"
        return 1
      fi
      ;;
    stack)
      rice-restart hypr || true
      rice-restart portal || true
      rice-restart waybar || true
      ;;
    *)
      echo "Usage: rice-restart [stack|hypr|waybar|portal]"
      return 1
      ;;
  esac
}

rice-autodetect() {
  if [[ -x "$HOME/dot-files/scripts/post_install_autodetect.sh" ]]; then
    bash "$HOME/dot-files/scripts/post_install_autodetect.sh"
  else
    echo "Autodetect script not found at ~/dot-files/scripts/post_install_autodetect.sh"
    return 1
  fi
}
