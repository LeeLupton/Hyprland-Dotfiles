#!/usr/bin/env python3
import importlib.util
import os
import math
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from array import array
import json
import wave

VOICE_CONTROL_PATH = Path.home() / ".config/hypr/scripts/voice_control.py"
SOURCE = os.environ.get("VOICE_SOURCE", "default")
CHUNK_SECS = float(os.environ.get("VOICE_HANDSFREE_CHUNK_SECS", "2.8"))
SLEEP_SECS = float(os.environ.get("VOICE_HANDSFREE_SLEEP_SECS", "0.2"))
MIN_WAV_BYTES = int(os.environ.get("VOICE_HANDSFREE_MIN_WAV_BYTES", "4096"))
MIN_RMS = float(os.environ.get("VOICE_HANDSFREE_MIN_RMS", "350"))
REQUIRE_WAKE = os.environ.get("VOICE_HANDSFREE_REQUIRE_WAKE", "1").lower() not in ("0", "false", "no")
WAKE_WORD = os.environ.get("VOICE_WAKE_WORD", "codex").strip().lower()
PASTE_REPLY = os.environ.get("VOICE_HANDSFREE_PASTE_REPLY", "0").lower() in ("1", "true", "yes")
DEDUPE_WINDOW_SECS = float(os.environ.get("VOICE_HANDSFREE_DEDUPE_WINDOW_SECS", "2.0"))
DEBUG_POPUP = os.environ.get("VOICE_HANDSFREE_DEBUG_POPUP", "0").lower() in ("1", "true", "yes")
STT_MODE = os.environ.get("VOICE_HANDSFREE_STT_MODE", "auto").strip().lower()
ENGLISH_ONLY = os.environ.get("VOICE_HANDSFREE_ENGLISH_ONLY", "1").lower() not in ("0", "false", "no")
ALLOW_COMMAND_PREFIX = os.environ.get("VOICE_COMMAND_PREFIX", "0").lower() in ("1", "true", "yes")
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


def _playback_active() -> bool:
    pid_path = getattr(vc, "PLAYBACK_PID", "/tmp/rudy_voice_playback.pid")
    if os.path.isfile(pid_path):
        try:
            with open(pid_path, "r", encoding="utf-8") as f:
                pid = int((f.read() or "0").strip())
            if pid > 0:
                os.kill(pid, 0)
                return True
        except Exception:
            pass
    return False


def _record_chunk(path: str) -> bool:
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
        subprocess.run(cmd, check=False, timeout=max(6.0, CHUNK_SECS + 3.0))
    except Exception as exc:
        vc.log_event("warn", "handsfree_record_error", "Chunk capture failed", error=str(exc))
        return False
    try:
        return os.path.getsize(path) >= MIN_WAV_BYTES
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
        vc.log_event("warn", "handsfree_local_stt_unavailable", "Vosk module not available in venv")
        _LOCAL_STT_READY = False
        return None
    model_path = getattr(vc, "MODEL_PATH", "")
    if not model_path or not os.path.isdir(model_path):
        vc.log_event("warn", "handsfree_local_model_missing", "Vosk model path missing", path=model_path)
        _LOCAL_STT_READY = False
        return None
    _LOCAL_MODEL = model_cls(model_path)
    _LOCAL_STT_READY = True
    vc.log_event("info", "handsfree_local_model_loaded", "Loaded local Vosk model", path=model_path)
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
        vc.log_event("warn", "handsfree_local_stt_error", "Local STT failed", error=str(exc))
        return ""


def _transcribe_chunk(path: str) -> str:
    if STT_MODE == "openai":
        return vc.transcribe_openai(path)
    if STT_MODE == "local":
        return _transcribe_local(path)
    model = _init_local_model()
    if model is not None:
        return _transcribe_local(path)
    # Fallback only when local STT is unavailable.
    return vc.transcribe(path)


def _has_voice_energy(path: str) -> bool:
    try:
        with wave.open(path, "rb") as wf:
            frames = wf.readframes(wf.getnframes())
            if not frames:
                return False
            if wf.getsampwidth() != 2:
                return True
            samples = array("h")
            samples.frombytes(frames)
            if not samples:
                return False
            sq = 0.0
            for s in samples:
                sq += float(s) * float(s)
            rms = math.sqrt(sq / len(samples))
            return rms >= MIN_RMS
    except Exception:
        return True


def _strip_wake(text: str) -> str:
    if not WAKE_WORD:
        return text
    if text == WAKE_WORD:
        return ""
    prefix = WAKE_WORD + " "
    if text.startswith(prefix):
        return text[len(prefix) :].strip()
    return text


def _is_english_text(text: str) -> bool:
    if not text:
        return False
    if any(ord(c) > 127 for c in text):
        return False
    # Require at least one ASCII letter so punctuation/noise does not pass.
    return any("a" <= c <= "z" for c in text.lower())


def _is_safe_prefix_command(text: str, key: str) -> bool:
    if not ALLOW_COMMAND_PREFIX:
        return False
    if not text.startswith(key + " "):
        return False
    suffix = text[len(key):].strip().lower()
    return suffix in {"please", "now", "for me", "thanks", "thank you"}


def _maybe_handle_builtin(text: str) -> bool:
    # Keep parity with push-to-talk assistant conveniences.
    if text.startswith("type "):
        payload = text[5:]
        vc.send_paste(payload)
        vc.speak("Typed.")
        vc.log_event("info", "handsfree_type", "Handled type command", chars=len(payload))
        return True
    if text.startswith("dictate "):
        payload = text[8:]
        vc.send_paste(payload)
        vc.speak("Dictated.")
        vc.log_event("info", "handsfree_dictate", "Handled dictate command", chars=len(payload))
        return True
    if text.startswith("weather in "):
        loc = text[len("weather in ") :].strip()
        weather = vc.get_weather(loc)
        vc.speak(weather if weather else "Sorry, I couldn't get the forecast.")
        return True
    if text.startswith("weather for "):
        loc = text[len("weather for ") :].strip()
        weather = vc.get_weather(loc)
        vc.speak(weather if weather else "Sorry, I couldn't get the forecast.")
        return True
    return False


def _dispatch_command_or_chat(text: str) -> None:
    if text in vc.COMMANDS:
        if not vc.cooldown_hit(text):
            vc.play_ding()
            vc.run_command(vc.COMMANDS[text])
            vc.log_event("info", "handsfree_command_exact", "Matched command", key=text)
        return
    for k, v in vc.COMMANDS.items():
        if _is_safe_prefix_command(text, k):
            if not vc.cooldown_hit(k):
                vc.play_ding()
                vc.run_command(v)
                vc.log_event("info", "handsfree_command_prefix", "Matched command safe prefix", key=k, transcript=text)
            return

    history = vc.load_history()
    reply = vc.chat_openai(text, history)
    if not reply:
        return
    history.append({"role": "user", "content": text})
    history.append({"role": "assistant", "content": reply})
    vc.save_history(history)
    if PASTE_REPLY:
        vc.send_paste(reply)
    vc.speak(reply)
    vc.log_event("info", "handsfree_chat_reply", "Spoke assistant reply", chars=len(reply))


def _debug_popup(text: str) -> None:
    if not DEBUG_POPUP or not text:
        return
    vc.show_popup(text)


def main() -> None:
    signal.signal(signal.SIGINT, _sig_handler)
    signal.signal(signal.SIGTERM, _sig_handler)
    vc.log_event(
        "info",
        "handsfree_daemon_start",
        "Hands-free assistant daemon started",
        source=SOURCE,
        chunk_secs=CHUNK_SECS,
        min_rms=MIN_RMS,
        require_wake=REQUIRE_WAKE,
        wake_word=WAKE_WORD,
        debug_popup=DEBUG_POPUP,
        stt_mode=STT_MODE,
        english_only=ENGLISH_ONLY,
        command_prefix=ALLOW_COMMAND_PREFIX,
    )

    if not shutil_which("ffmpeg"):
        vc.log_event("error", "handsfree_missing_ffmpeg", "ffmpeg not found")
        while RUN:
            time.sleep(2)
        return

    last_text = ""
    last_text_ts = 0.0

    while RUN:
        # Avoid feedback loop while TTS is speaking.
        if _playback_active():
            time.sleep(SLEEP_SECS)
            continue

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
            wav_path = tf.name

        try:
            if not _record_chunk(wav_path):
                time.sleep(SLEEP_SECS)
                continue
            if not _has_voice_energy(wav_path):
                continue
            raw = _transcribe_chunk(wav_path)
            text = vc.normalize(raw)
            text = vc.collapse_repeats(vc.normalize_wake(text))
            if not text:
                continue
            if ENGLISH_ONLY and not _is_english_text(text):
                vc.log_event("debug", "handsfree_non_english_skip", "Ignored non-English transcript", text=text)
                continue
            _debug_popup(f"HF raw: {text}")

            now = time.monotonic()
            if text == last_text and (now - last_text_ts) < DEDUPE_WINDOW_SECS:
                continue
            last_text = text
            last_text_ts = now
            vc.log_event("debug", "handsfree_transcript", "Transcript chunk", text=text)

            if REQUIRE_WAKE:
                stripped = _strip_wake(text)
                if stripped == text:
                    continue
                text = stripped
                if not text:
                    _debug_popup(f"HF wake: {WAKE_WORD}")
                    vc.play_ding()
                    continue
            else:
                text = _strip_wake(text)
                if not text:
                    continue
            _debug_popup(f"HF cmd: {text}")

            if _maybe_handle_builtin(text):
                continue
            _dispatch_command_or_chat(text)
        except Exception as exc:
            vc.log_event("warn", "handsfree_loop_error", "Hands-free loop iteration failed", error=str(exc))
        finally:
            try:
                os.unlink(wav_path)
            except OSError:
                pass
            time.sleep(SLEEP_SECS)

    vc.log_event("info", "handsfree_daemon_stop", "Hands-free assistant daemon stopped")


def shutil_which(cmd: str) -> bool:
    return subprocess.run(
        ["bash", "-lc", f"command -v {cmd} >/dev/null 2>&1"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


if __name__ == "__main__":
    main()
