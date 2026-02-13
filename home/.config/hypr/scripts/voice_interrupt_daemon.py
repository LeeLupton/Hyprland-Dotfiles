#!/usr/bin/env python3
import importlib.util
import os
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path
import json
import wave

VOICE_CONTROL_PATH = Path.home() / ".config/hypr/scripts/voice_control.py"
CHUNK_SECS = float(os.environ.get("VOICE_INTERRUPT_CHUNK_SECS", "1.2"))
SLEEP_SECS = float(os.environ.get("VOICE_INTERRUPT_SLEEP_SECS", "0.15"))
COOLDOWN_SECS = float(os.environ.get("VOICE_INTERRUPT_COOLDOWN_SECS", "0.8"))
STOP_PHRASES_ENV = os.environ.get(
    "VOICE_INTERRUPT_PHRASES",
    "stop talking,shut up,quiet,silence,stop",
)
STOP_PHRASES = [p.strip().lower() for p in STOP_PHRASES_ENV.split(",") if p.strip()]
SOURCE = os.environ.get("VOICE_SOURCE", "default")
DEBUG_POPUP = os.environ.get("VOICE_INTERRUPT_DEBUG_POPUP", "0").lower() in ("1", "true", "yes")
RUN = True
_LOCAL_MODEL = None
_LOCAL_STT_READY = None


def _load_voice_control():
    spec = importlib.util.spec_from_file_location("voice_control", VOICE_CONTROL_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Failed to load {VOICE_CONTROL_PATH}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


vc = _load_voice_control()


def _sig_handler(_sig, _frame):
    global RUN
    RUN = False


def _is_pid_running(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _playback_active() -> bool:
    pid_path = getattr(vc, "PLAYBACK_PID", "/tmp/rudy_voice_playback.pid")
    if os.path.isfile(pid_path):
        try:
            with open(pid_path, "r", encoding="utf-8") as f:
                pid = int((f.read() or "0").strip())
            if _is_pid_running(pid):
                return True
        except Exception:
            pass
    # Only arm interrupt detection when the voice assistant playback pid is active.
    return False


def _record_chunk(path: str) -> bool:
    if shutil.which("ffmpeg") is None:
        vc.log_event("error", "interrupt_missing_ffmpeg", "ffmpeg not found for interrupt daemon")
        time.sleep(2)
        return False
    cmd = [
        "ffmpeg",
        "-f",
        "pulse",
        "-i",
        SOURCE,
        "-ac",
        "1",
        "-ar",
        "16000",
        "-t",
        f"{CHUNK_SECS:.2f}",
        "-y",
        "-loglevel",
        "quiet",
        path,
    ]
    try:
        subprocess.run(cmd, check=False, timeout=max(5.0, CHUNK_SECS + 3.0))
    except Exception as exc:
        vc.log_event("warn", "interrupt_record_error", "Chunk capture failed", error=str(exc))
        return False
    try:
        return os.path.getsize(path) > 1024
    except Exception:
        return False


def _init_local_model():
    global _LOCAL_MODEL, _LOCAL_STT_READY
    if _LOCAL_MODEL is not None:
        return _LOCAL_MODEL
    if _LOCAL_STT_READY is False:
        return None
    model_cls = getattr(vc, "Model", None)
    if model_cls is None:
        vc.log_event("warn", "interrupt_local_stt_unavailable", "Vosk module not available in venv")
        _LOCAL_STT_READY = False
        return None
    model_path = getattr(vc, "MODEL_PATH", "")
    if not model_path or not os.path.isdir(model_path):
        vc.log_event("warn", "interrupt_local_model_missing", "Vosk model path missing", path=model_path)
        _LOCAL_STT_READY = False
        return None
    _LOCAL_MODEL = model_cls(model_path)
    _LOCAL_STT_READY = True
    vc.log_event("info", "interrupt_local_model_loaded", "Loaded local Vosk model", path=model_path)
    return _LOCAL_MODEL


def _transcribe_local(path: str) -> str:
    model = _init_local_model()
    recog_cls = getattr(vc, "KaldiRecognizer", None)
    if model is None or recog_cls is None:
        return ""
    try:
        rec = recog_cls(model, 16000)
        with wave.open(path, "rb") as wf:
            while True:
                data = wf.readframes(4000)
                if not data:
                    break
                rec.AcceptWaveform(data)
        res = json.loads(rec.FinalResult())
        return (res.get("text") or "").strip().lower()
    except Exception as exc:
        vc.log_event("warn", "interrupt_local_stt_error", "Local STT failed", error=str(exc))
        return ""


def _transcribe_chunk(path: str) -> str:
    model = _init_local_model()
    if model is not None:
        return _transcribe_local(path)
    return vc.transcribe(path)


def _heard_stop(text: str) -> bool:
    t = text.lower()
    return any(phrase in t for phrase in STOP_PHRASES)


def _debug_popup(text: str) -> None:
    if not DEBUG_POPUP or not text:
        return
    vc.show_popup(text)


def main() -> None:
    signal.signal(signal.SIGINT, _sig_handler)
    signal.signal(signal.SIGTERM, _sig_handler)
    vc.log_event(
        "info",
        "interrupt_daemon_start",
        "Hands-free interrupt daemon started",
        chunk_secs=CHUNK_SECS,
        source=SOURCE,
        stt_mode=("openai" if os.environ.get("VOICE_STT", "").lower() == "openai" else "local"),
        debug_popup=DEBUG_POPUP,
    )

    last_interrupt = 0.0
    while RUN:
        if not _playback_active():
            time.sleep(SLEEP_SECS)
            continue

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            wav_path = tf.name

        try:
            if not _record_chunk(wav_path):
                time.sleep(SLEEP_SECS)
                continue

            text = vc.normalize(_transcribe_chunk(wav_path))
            if not text:
                continue
            vc.log_event("debug", "interrupt_transcript", "Interrupt chunk transcript", text=text)
            _debug_popup(f"INT heard: {text}")

            now = time.monotonic()
            if _heard_stop(text) and (now - last_interrupt) >= COOLDOWN_SECS:
                vc.stop_playback()
                vc.log_event("info", "interrupt_triggered", "Playback interrupted by voice", transcript=text)
                _debug_popup("INT triggered")
                last_interrupt = now
        except Exception as exc:
            vc.log_event("warn", "interrupt_loop_error", "Interrupt loop iteration failed", error=str(exc))
        finally:
            try:
                os.unlink(wav_path)
            except OSError:
                pass
            time.sleep(SLEEP_SECS)

    vc.log_event("info", "interrupt_daemon_stop", "Hands-free interrupt daemon stopped")


if __name__ == "__main__":
    main()
