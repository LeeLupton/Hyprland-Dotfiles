# dot-files

Portable snapshot of this Arch Linux rice and user environment.

## Quick start (Arch)

```bash
cd ~/dot-files
bash ./bootstrap.sh
```

Safe execution options:

```bash
bash ./bootstrap.sh --dry-run
bash ./bootstrap.sh --yes
```

This runs:
1. `scripts/install_dependencies.sh`
2. `scripts/apply_dotfiles.sh`
3. `scripts/post_install_autodetect.sh`

## What is included

- Window manager + desktop config (`hypr`, `waybar`, `rofi`, `wlogout`, `swaync`, `wallust`)
- Terminal/shell config (`.zshrc`, `.p10k.zsh`, `.tmux.conf`, etc.)
- Themes and icons (`~/.themes`, `~/.icons`)
- Custom scripts (`~/waybar-scripts`, Hypr scripts)
- Package manifests from this machine (`manifests/`)

## Repository layout

- `bootstrap.sh` - one-command setup for Arch
- `scripts/install_dependencies.sh` - installs pacman, AUR, pipx, npm dependencies
- `scripts/apply_dotfiles.sh` - applies files to `$HOME` with timestamped backups
- `scripts/post_install_autodetect.sh` - detects interface/audio/DM/lock manager and patches config dynamically
- `manifests/` - package and requirements manifests
- `home/` - files copied into your home directory
- `docs/REQUIREMENTS.md` - prerequisites and caveats

## Backup and restore behavior

Applying dotfiles creates backups in:

```bash
~/.dotfiles-backup/<timestamp>
```

If needed, restore manually from that backup directory.

## Notes

- Secrets are not bundled. Use `home/.env.example` as a template for `~/.env`.
- Hardware-specific values are auto-detected during bootstrap:
  - Waybar traffic interface (`TRAFFIC_IFACE`)
  - Voice input source (`VOICE_SOURCE`)
  - Hyprland monitor layout (when `hyprctl` is available in-session)
  - Display manager and lock manager
- This snapshot is large because icon themes are included.

## Runtime commands

After login, shell helpers are available:

- `rice-check` - show Hyprland/Wayland/portal/driver/session health
- `rice-restart [stack|hypr|waybar|portal]` - restart components quickly
- `rice-autodetect` - re-run dynamic detection and patching

## Safety model

- All main scripts validate required tools before making changes.
- Package installs use fallback retries (bulk, then per-package).
- Apply step creates timestamped backups before writing.
- Bootstrap supports selective skips:
  - `--skip-install`
  - `--skip-apply`
  - `--skip-autodetect`
