# dot-files

Portable snapshot of this Arch Linux rice and user environment.

## Quick start (Arch)

```bash
cd ~/dot-files
bash ./bootstrap.sh
```

This runs:
1. `scripts/install_dependencies.sh`
2. `scripts/apply_dotfiles.sh`

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
- Some config values are hardware-specific (monitors, audio devices, network interface names).
- This snapshot is large because icon themes are included.
