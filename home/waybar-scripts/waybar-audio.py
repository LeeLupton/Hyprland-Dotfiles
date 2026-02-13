#!/usr/bin/env python3

import sys
import json
import time
import signal
import waybar_utils

try:
    import pulsectl
except ImportError:
    waybar_utils.output_error("Dependency Error", "pulsectl module not installed")
    sys.exit(1)

# Configuration
# Visualizer width in chars
VU_CHARS = 10 

def generate_vu(percent):
    # Cap at 100% for visual consistency, or handle overamplification
    val = int(min(percent, 150) / 150 * VU_CHARS)
    if val > VU_CHARS: val = VU_CHARS
    
    # 0..100 map to 0..10
    # Actually standard is 100%. 150% is max boost.
    # Let's map 0-100 to 0-8 chars, and >100 to red chars?
    # Simple bar:
    bar = "█" * int(min(percent, 100) / 100 * VU_CHARS)
    pad = "░" * (VU_CHARS - len(bar))
    return f"{bar}{pad}"

def print_state(pulse):
    try:
        server_info = pulse.server_info()
        
        # Sink
        sink = pulse.get_sink_by_name(server_info.default_sink_name)
        if sink:
            spk_vol = int(round(sink.volume.value_flat * 100))
            spk_mute = sink.mute
            spk_desc = sink.description
        else:
            spk_vol = 0
            spk_mute = False
            spk_desc = "Unknown"

        # Source
        source = pulse.get_source_by_name(server_info.default_source_name)
        if source:
            mic_vol = int(round(source.volume.value_flat * 100))
            mic_mute = source.mute
            mic_desc = source.description
        else:
            mic_vol = 0
            mic_mute = False
            mic_desc = "Unknown"

        # Format Output
        # Mic
        mic_icon = "" if not mic_mute else ""
        mic_text = f"{mic_icon} {mic_vol}%"
        
        # Speaker
        spk_icon = ""
        if spk_mute: spk_icon = "󰖁"
        elif spk_vol < 30: spk_icon = ""
        elif spk_vol < 70: spk_icon = ""
        
        spk_text = f"{spk_icon} {spk_vol}%"
        
        # Combined Text
        # text = f"{mic_text}  {spk_text}"
        # User might prefer VU meter style?
        # "♪ {text}" is format in config.
        
        text = f"Mic: {mic_text}  Spk: {spk_text}"
        
        tooltip = (f"<b>Speaker</b>\n{spk_desc}\nVolume: {spk_vol}%\n\n"
                   f"<b>Microphone</b>\n{mic_desc}\nVolume: {mic_vol}%")
        
        css_class = "audio-monitor"
        if spk_mute or mic_mute:
            css_class = "audio-monitor-muted"

        output = {
            "text": text,
            "tooltip": tooltip,
            "class": css_class
        }
        
        print(json.dumps(output), flush=True)

    except Exception as e:
        # Fallback
        pass

def main():
    # Signal handling
    def handler(sig, frame):
        sys.exit(0)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)

    while True:
        try:
            with pulsectl.Pulse('waybar-audio-daemon') as pulse:
                # Initial print
                print_state(pulse)
                
                # Listen for events
                # mask: 'sink', 'source', 'server' (for default changes)
                # This block blocks until an event occurs
                for event in pulse.event_listen():
                    if event.facility in ['sink', 'source', 'server']:
                        print_state(pulse)
                        
        except pulsectl.PulseDisconnected:
            # Connection lost, wait and retry
            time.sleep(2)
        except Exception as e:
            # Other error
            time.sleep(2)

if __name__ == '__main__':
    main()
