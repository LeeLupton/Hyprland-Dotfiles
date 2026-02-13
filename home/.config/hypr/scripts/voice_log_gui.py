#!/usr/bin/env python3
import argparse
import os
import tkinter as tk
from tkinter import ttk
from collections import deque


DEFAULT_EVENT_LOG = os.environ.get("VOICE_EVENT_LOG", "/tmp/voice_control_events.log")
DEFAULT_TEXT_LOG = os.environ.get("VOICE_LOG", "/tmp/voice_control.log")
POLL_MS = int(os.environ.get("VOICE_GUI_POLL_MS", "400"))
MAX_LINES = int(os.environ.get("VOICE_GUI_MAX_LINES", "800"))


def parse_fields(raw: str) -> dict:
    out = {}
    if not raw:
        return out
    for part in raw.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k] = v
    return out


def parse_event_line(line: str):
    parts = line.rstrip("\n").split("|", 6)
    if len(parts) != 7:
        return None
    return {
        "ts_ms": parts[0],
        "iso": parts[1],
        "level": parts[2],
        "component": parts[3],
        "event": parts[4],
        "message": parts[5],
        "fields_raw": parts[6],
        "fields": parse_fields(parts[6]),
    }


class VoiceLogGUI:
    def __init__(self, root, event_log_path: str, text_log_path: str):
        self.root = root
        self.event_log_path = event_log_path
        self.text_log_path = text_log_path
        self.offset = 0
        self.inode = None
        self.buffer = deque(maxlen=MAX_LINES)

        self.state_var = tk.StringVar(value="idle")
        self.transcript_var = tk.StringVar(value="-")
        self.command_var = tk.StringVar(value="-")
        self.error_var = tk.StringVar(value="-")
        self.stats_var = tk.StringVar(value=f"event log: {self.event_log_path}")

        self.build_ui()
        self.poll()

    def build_ui(self):
        self.root.title("Rudy Voice Logs")
        self.root.geometry("1100x700")

        frame = ttk.Frame(self.root, padding=8)
        frame.pack(fill=tk.BOTH, expand=True)

        status = ttk.Frame(frame)
        status.pack(fill=tk.X, pady=(0, 8))

        ttk.Label(status, text="State:", width=12).grid(row=0, column=0, sticky="w")
        ttk.Label(status, textvariable=self.state_var).grid(row=0, column=1, sticky="w")
        ttk.Label(status, text="Transcript:", width=12).grid(row=1, column=0, sticky="w")
        ttk.Label(status, textvariable=self.transcript_var).grid(row=1, column=1, sticky="w")
        ttk.Label(status, text="Command:", width=12).grid(row=2, column=0, sticky="w")
        ttk.Label(status, textvariable=self.command_var).grid(row=2, column=1, sticky="w")
        ttk.Label(status, text="Last Error:", width=12).grid(row=3, column=0, sticky="w")
        ttk.Label(status, textvariable=self.error_var).grid(row=3, column=1, sticky="w")

        controls = ttk.Frame(frame)
        controls.pack(fill=tk.X, pady=(0, 8))
        ttk.Button(controls, text="Clear Event Log", command=self.clear_event_log).pack(side=tk.LEFT)
        ttk.Button(controls, text="Clear Text Log", command=self.clear_text_log).pack(side=tk.LEFT, padx=(8, 0))
        ttk.Button(controls, text="Refresh", command=self.refresh_full).pack(side=tk.LEFT, padx=(8, 0))

        body = ttk.Frame(frame)
        body.pack(fill=tk.BOTH, expand=True)

        self.text = tk.Text(body, wrap="none", font=("monospace", 10))
        yscroll = ttk.Scrollbar(body, orient="vertical", command=self.text.yview)
        xscroll = ttk.Scrollbar(body, orient="horizontal", command=self.text.xview)
        self.text.configure(yscrollcommand=yscroll.set, xscrollcommand=xscroll.set)

        self.text.grid(row=0, column=0, sticky="nsew")
        yscroll.grid(row=0, column=1, sticky="ns")
        xscroll.grid(row=1, column=0, sticky="ew")
        body.grid_rowconfigure(0, weight=1)
        body.grid_columnconfigure(0, weight=1)

        ttk.Label(frame, textvariable=self.stats_var).pack(fill=tk.X, pady=(8, 0))

    def clear_event_log(self):
        try:
            open(self.event_log_path, "w", encoding="utf-8").close()
        except OSError as exc:
            self.error_var.set(f"clear event log failed: {exc}")
        self.offset = 0
        self.inode = None
        self.buffer.clear()
        self.text.delete("1.0", tk.END)

    def clear_text_log(self):
        try:
            open(self.text_log_path, "w", encoding="utf-8").close()
        except OSError as exc:
            self.error_var.set(f"clear text log failed: {exc}")

    def refresh_full(self):
        self.offset = 0
        self.inode = None
        self.buffer.clear()
        self.text.delete("1.0", tk.END)

    def apply_event(self, ev: dict):
        line = f"{ev['iso']} [{ev['level']}] {ev['component']}.{ev['event']} {ev['message']} {ev['fields_raw']}".rstrip()
        self.buffer.append(line)

        event = ev["event"]
        fields = ev["fields"]
        if event in ("start_recording", "recorder_started"):
            self.state_var.set("recording")
        elif event in ("stop_recording", "handoff_transcribe"):
            self.state_var.set("processing")
        elif event in ("chat_reply_spoken", "command_matched", "command_matched_prefix"):
            self.state_var.set("idle")
        elif event == "transcribe_raw":
            self.transcript_var.set(fields.get("text", ev["message"]) or "-")
        elif event in ("command_matched", "command_matched_prefix"):
            self.command_var.set(fields.get("key", ev["message"]) or "-")
        elif ev["level"] == "ERROR":
            self.error_var.set(f"{event}: {ev['message']}")

    def redraw(self):
        self.text.delete("1.0", tk.END)
        for ln in self.buffer:
            self.text.insert(tk.END, ln + "\n")
        self.text.see(tk.END)
        self.stats_var.set(
            f"events: {len(self.buffer)} | state: {self.state_var.get()} | source: {self.event_log_path}"
        )

    def poll(self):
        try:
            st = os.stat(self.event_log_path)
            if self.inode != st.st_ino or st.st_size < self.offset:
                self.inode = st.st_ino
                self.offset = 0
                self.buffer.clear()
            with open(self.event_log_path, "r", encoding="utf-8", errors="replace") as f:
                f.seek(self.offset)
                new_lines = f.readlines()
                self.offset = f.tell()
            changed = False
            for ln in new_lines:
                ev = parse_event_line(ln)
                if ev is None:
                    continue
                self.apply_event(ev)
                changed = True
            if changed:
                self.redraw()
        except FileNotFoundError:
            pass
        except Exception as exc:
            self.error_var.set(str(exc))
        finally:
            self.root.after(POLL_MS, self.poll)


def main():
    parser = argparse.ArgumentParser(description="Rudy voice log GUI")
    parser.add_argument("--event-log", default=DEFAULT_EVENT_LOG)
    parser.add_argument("--text-log", default=DEFAULT_TEXT_LOG)
    args = parser.parse_args()

    if not os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
        print("No graphical display found. Set WAYLAND_DISPLAY or DISPLAY.")
        return

    root = tk.Tk()
    VoiceLogGUI(root, args.event_log, args.text_log)
    root.mainloop()


if __name__ == "__main__":
    main()
