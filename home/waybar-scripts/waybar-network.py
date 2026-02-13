#!/usr/bin/env python3

import time
import json
import waybar_utils
from pathlib import Path

# Setup logging
logger = waybar_utils.setup_logger("waybar-network")

# State file for storing previous counters
STATE_FILE = Path.home() / ".cache" / "waybar-scripts" / "network_state.json"

# Default config
DEFAULT_CONFIG = {
    "interface": "auto",  # auto-detect
    "interval": 1
}

config = waybar_utils.load_config("waybar-network", DEFAULT_CONFIG)

def get_bytes(interface):
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()
        
        for line in lines:
            if interface in line:
                data = line.split(':')[1].split()
                rx = int(data[0])
                tx = int(data[8])
                return rx, tx
    except Exception as e:
        # logger.error(f"Error reading network stats: {e}") 
        # Reducing log spam for "interface not found" during switching
        pass
    return 0, 0

def format_bytes(size):
    power = 2**10
    n = 0
    power_labels = {0 : '', 1: 'K', 2: 'M', 3: 'G', 4: 'T'}
    while size > power:
        size /= power
        n += 1
    return f"{size:.1f}{power_labels.get(n, '')}B/s"

def get_active_interface(configured_iface):
    if configured_iface != "auto":
        # Check if it exists
        if get_bytes(configured_iface) != (0,0):
            return configured_iface
    
    # Auto-detect
    best_iface = "lo"
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()[2:]
            
        # Priority: Ethernet > Wifi > Others
        # Simple heuristic: ignore lo, look for known prefixes or just first one
        candidates = []
        for line in lines:
            iface = line.split(':')[0].strip()
            if iface != "lo":
                candidates.append(iface)
        
        # Heuristic sort (eth/enp first, then wlan/wlp)
        candidates.sort(key=lambda x: (not x.startswith('e'), not x.startswith('w'), x))
        
        if candidates:
            return candidates[0]
            
    except Exception:
        pass
    return best_iface

@waybar_utils.safe_run
def main():
    target_iface = get_active_interface(config.get("interface", "auto"))
    
    current_time = time.time()
    rx_now, tx_now = get_bytes(target_iface)
    
    # Load previous state
    prev_state = {}
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, 'r') as f:
                prev_state = json.load(f)
        except Exception:
            pass
            
    # Calculate deltas
    prev_time = prev_state.get("time", current_time - 1) # Default to 1s ago if missing
    prev_rx = prev_state.get("rx", 0)
    prev_tx = prev_state.get("tx", 0)
    prev_iface = prev_state.get("iface", target_iface)
    
    # If interface changed, reset counters to 0 speed for this tick
    if prev_iface != target_iface:
        rx_speed = 0
        tx_speed = 0
    else:
        time_delta = current_time - prev_time
        if time_delta <= 0: time_delta = 1 # Avoid div by zero
        
        rx_speed = (rx_now - prev_rx) / time_delta
        tx_speed = (tx_now - prev_tx) / time_delta
        
        # Handle overflow or reboot (counters reset)
        if rx_speed < 0: rx_speed = 0
        if tx_speed < 0: tx_speed = 0

    # Save current state
    new_state = {
        "time": current_time,
        "rx": rx_now,
        "tx": tx_now,
        "iface": target_iface
    }
    try:
        with open(STATE_FILE, 'w') as f:
            json.dump(new_state, f)
    except Exception as e:
        logger.error(f"Failed to save state: {e}")

    # Output
    text = f"⬇{format_bytes(rx_speed)} ⬆{format_bytes(tx_speed)}"
    tooltip = f"Interface: {target_iface}\nRX: {format_bytes(rx_speed)}\nTX: {format_bytes(tx_speed)}"
    
    css_class = "network"
    if rx_speed > 1024 * 1024 * 5: # 5MB/s
        css_class = "network-high"
        
    waybar_utils.output_json({
        "text": text,
        "tooltip": tooltip,
        "class": css_class,
        "alt": target_iface
    })

if __name__ == '__main__':
    main()
