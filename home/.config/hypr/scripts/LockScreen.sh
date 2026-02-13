#!/usr/bin/env bash
# /* ---- 💫 https://github.com/JaKooLit 💫 ---- */  ##

# For Hyprlock
#pidof hyprlock || hyprlock -q

# Ensure weather cache is up-to-date before locking (Waybar/lockscreen readers)
bash "$HOME/.config/hypr/UserScripts/WeatherWrap.sh" >/dev/null 2>&1

if [[ -f "$HOME/.config/dotfiles/autodetect.env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/dotfiles/autodetect.env"
fi

LOCK_MANAGER="${DOTFILES_LOCK_MANAGER:-hyprlock}"
case "$LOCK_MANAGER" in
  hyprlock)
    if command -v hyprlock >/dev/null 2>&1; then
      pidof hyprlock >/dev/null 2>&1 || hyprlock -q
      exit 0
    fi
    ;;
  swaylock)
    if command -v swaylock >/dev/null 2>&1; then
      pidof swaylock >/dev/null 2>&1 || swaylock -f
      exit 0
    fi
    ;;
  gtklock)
    if command -v gtklock >/dev/null 2>&1; then
      pidof gtklock >/dev/null 2>&1 || gtklock
      exit 0
    fi
    ;;
  i3lock)
    if command -v i3lock >/dev/null 2>&1; then
      pidof i3lock >/dev/null 2>&1 || i3lock
      exit 0
    fi
    ;;
esac

loginctl lock-session
