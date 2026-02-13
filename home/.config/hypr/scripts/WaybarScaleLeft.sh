#!/usr/bin/env bash
set -euo pipefail

WAYBAR_CONFIG_LINK="$HOME/.config/waybar/config"
WAYBAR_STYLE_LINK="$HOME/.config/waybar/style.css"

config_path=$(readlink -f "$WAYBAR_CONFIG_LINK")
style_path=$(readlink -f "$WAYBAR_STYLE_LINK")

if [[ -z "$config_path" || -z "$style_path" ]]; then
  echo "Waybar config/style not found" >&2
  exit 1
fi

python3 - <<'PY'
import json, os, re, subprocess
from pathlib import Path

config_path = Path(os.path.expanduser(os.environ.get("WAYBAR_CONFIG", "~/.config/waybar/config"))).resolve()
style_path = Path(os.path.expanduser(os.environ.get("WAYBAR_STYLE", "~/.config/waybar/style.css"))).resolve()

def get_resolution():
    try:
        out = subprocess.check_output(["hyprctl", "monitors", "-j"], text=True, timeout=1.5)
        mons = json.loads(out)
        if mons:
            mon = next((m for m in mons if m.get("focused")), None) or next((m for m in mons if m.get("primary")), None) or mons[0]
            return int(mon.get("width", 1920)), int(mon.get("height", 1080))
    except Exception:
        return 1920, 1080
    return 1920, 1080

w, h = get_resolution()
scale = h / 1080.0
scale = max(0.9, min(1.6, scale))

panel_height = max(360, int(520 * scale))
margin = max(3, int(6 * scale))
spacing = max(2, int(3 * scale))
font_size = max(9, int(11 * scale))
# enforce minimum width so Waybar doesn't auto-expand
fixed_width = max(110, int(120 * scale))

text = config_path.read_text()
left_block = re.split(r'\n}\s*,\s*\n\{', text, maxsplit=1)
if len(left_block) == 2:
    top, rest = left_block
    block = "{" + rest
    block = re.sub(r'"height"\s*:\s*\d+', f'"height": {panel_height}', block)
    block = re.sub(r'"margin-top"\s*:\s*\d+', f'"margin-top": {margin}', block)
    block = re.sub(r'"margin-bottom"\s*:\s*\d+', f'"margin-bottom": {margin}', block)
    block = re.sub(r'"spacing"\s*:\s*\d+', f'"spacing": {spacing}', block)
    if re.search(r'"width"\s*:', block):
        block = re.sub(r'"width"\s*:\s*\d+', f'"width": {fixed_width}', block)
    else:
        block = block.replace('"position": "left",', f'"position": "left",\n"width": {fixed_width},')
    text = top + "\n},\n" + block
else:
    text = re.sub(r'"height"\s*:\s*\d+', f'"height": {panel_height}', text)
    text = re.sub(r'"margin-top"\s*:\s*\d+', f'"margin-top": {margin}', text)
    text = re.sub(r'"margin-bottom"\s*:\s*\d+', f'"margin-bottom": {margin}', text)
    text = re.sub(r'"spacing"\s*:\s*\d+', f'"spacing": {spacing}', text)

config_path.write_text(text)

css = style_path.read_text()
block = f"""
/* AUTO-SCALE-LEFT:BEGIN */
window#waybar.left {{
  font-size: {font_size}px;
}}
window#waybar.left #custom-traffic {{
  font-size: {max(8, int(font_size * 0.95))}px;
}}
/* AUTO-SCALE-LEFT:END */
"""

if "/* AUTO-SCALE-LEFT:BEGIN */" in css:
    css = re.sub(r'/\* AUTO-SCALE-LEFT:BEGIN \*/.*?/\* AUTO-SCALE-LEFT:END \*/', block, css, flags=re.S)
else:
    css = css.rstrip() + "\n" + block

style_path.write_text(css)
print(f"Scaled left panel: height={panel_height}, margin={margin}, spacing={spacing}, font={font_size}px, width={fixed_width}px (resolution={w}x{h})")
PY
