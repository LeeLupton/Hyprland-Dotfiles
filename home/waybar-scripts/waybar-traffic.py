#!/usr/bin/env python3

import time
import json
import sys
import signal
import waybar_utils

# Configuration
RAIN_HEIGHT = 20
UPDATE_INTERVAL = 0.2 # 5 FPS

# Characters for intensity (High -> Low)
CHARS = ["█", "▓", "▒", "░", "·"]
# Colors
COLORS = {
    'TCP': '#f38ba8',   # Red
    'UDP': '#89b4fa',   # Blue
    'ICMP': '#a6e3a1',  # Green
    'IDLE': '#45475a'   # Surface
}

def get_snmp_stats():
    """Reads /proc/net/snmp for TCP, UDP, ICMP packet counts."""
    stats = {'TCP': 0, 'UDP': 0, 'ICMP': 0}
    try:
        with open('/proc/net/snmp', 'r') as f:
            lines = f.readlines()
        
        for i in range(0, len(lines), 2):
            header = lines[i].split()
            values = lines[i+1].split()
            protocol = header[0].strip(':')
            
            if protocol == 'Tcp':
                in_idx = header.index('InSegs')
                out_idx = header.index('OutSegs')
                stats['TCP'] = int(values[in_idx]) + int(values[out_idx])
            elif protocol == 'Udp':
                in_idx = header.index('InDatagrams')
                out_idx = header.index('OutDatagrams')
                stats['UDP'] = int(values[in_idx]) + int(values[out_idx])
            elif protocol == 'Icmp':
                in_idx = header.index('InMsgs')
                out_idx = header.index('OutMsgs')
                stats['ICMP'] = int(values[in_idx]) + int(values[out_idx])
    except Exception:
        pass
    return stats

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
    except Exception:
        pass
    return 0, 0

def get_active_interface(configured_iface="auto"):
    # Simplified auto-detect for loop
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()[2:]
        candidates = []
        for line in lines:
            iface = line.split(':')[0].strip()
            if iface != "lo":
                candidates.append(iface)
        candidates.sort(key=lambda x: (not x.startswith('e'), not x.startswith('w'), x))
        if candidates:
            return candidates[0]
    except Exception:
        pass
    return "lo"

def format_bytes_short(size):
    power = 2**10
    n = 0
    power_labels = {0 : '', 1: 'K', 2: 'M', 3: 'G', 4: 'T'}
    while size > power:
        size /= power
        n += 1
    if size >= 10 or n == 0:
        return f"{int(size)}{power_labels.get(n, '')}"
    return f"{size:.1f}{power_labels.get(n, '')}"

def signal_handler(sig, frame):
    sys.exit(0)

def main():
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    target_iface = get_active_interface()
    
    # State Init
    last_time = time.time()
    last_rx, last_tx = get_bytes(target_iface)
    last_snmp = get_snmp_stats()
    
    rain_history = []
    
    # Auto-scaling
    # We maintain a sliding window of max packets/sec to normalize intensity
    max_rate_history = [100] * 20 # init with some baseline
    
    while True:
        current_time = time.time()
        time_delta = current_time - last_time
        if time_delta < 0.01: # Avoid excessively fast loops or div/0
            time.sleep(UPDATE_INTERVAL)
            continue
            
        rx_now, tx_now = get_bytes(target_iface)
        snmp_now = get_snmp_stats()
        
        # Calculate Rates
        rx_speed = (rx_now - last_rx) / time_delta
        tx_speed = (tx_now - last_tx) / time_delta
        if rx_speed < 0: rx_speed = 0
        if tx_speed < 0: tx_speed = 0
        
        total_packets = 0
        max_proto = 'IDLE'
        max_val = 0
        
        for proto in ['TCP', 'UDP', 'ICMP']:
            curr = snmp_now.get(proto, 0)
            prev = last_snmp.get(proto, 0)
            # Handle counter reset
            if curr < prev: prev = curr 
            
            rate = (curr - prev) / time_delta
            total_packets += rate
            if rate > max_val:
                max_val = rate
                max_proto = proto
        
        # Update Scaling History
        max_rate_history.append(total_packets)
        max_rate_history = max_rate_history[-50:] # Keep last 50 samples
        global_max = max(max_rate_history)
        if global_max < 10: global_max = 10 # Floor
        
        # Determine Character (Intensity)
        # Intensity 0..1
        intensity = total_packets / global_max
        if intensity > 1: intensity = 1
        
        # Map 0..1 to CHARS index
        # 1.0 -> 0 (█)
        # 0.75 -> 1 (▓)
        # 0.50 -> 2 (▒)
        # 0.25 -> 3 (░)
        # 0.0 -> 4 (·)
        
        if total_packets < 1:
            char_idx = 4
        else:
            # Invert: 1.0 is index 0
            char_idx = int((1.0 - intensity) * 4) 
            if char_idx < 0: char_idx = 0
            if char_idx > 3: char_idx = 3
            
        char = CHARS[char_idx]
        color = COLORS.get(max_proto, COLORS['IDLE'])
        if max_proto == 'IDLE':
            char = CHARS[4] # force dot
        
        new_drop = f"<span color='{color}'>{char}</span>"
        
        # Update History
        rain_history.insert(0, new_drop)
        rain_history = rain_history[:RAIN_HEIGHT]
        
        # Render
        rain_str = "\n".join(rain_history)
        speed_str = f"\n<span size='small' color='#cba6f7'>⬇{format_bytes_short(rx_speed)}</span>\n<span size='small' color='#fab387'>⬆{format_bytes_short(tx_speed)}</span>"
        
        output = {
            "text": f"{rain_str}{speed_str}",
            "tooltip": f"Interface: {target_iface}\nPPS: {int(total_packets)}\nMix: {max_proto}",
            "class": "traffic-rain"
        }
        
        try:
            print(json.dumps(output), flush=True)
        except Exception:
            pass

        # Update State
        last_time = current_time
        last_rx = rx_now
        last_tx = tx_now
        last_snmp = snmp_now
        
        time.sleep(UPDATE_INTERVAL)

if __name__ == '__main__':
    main()