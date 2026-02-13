import json
import os
import subprocess
import sys
import tempfile
import wave
import time
import fcntl
import shutil
from datetime import datetime, timezone
from urllib import request
from urllib.error import URLError, HTTPError
import string

MODEL_PATH = os.path.expanduser("~/.config/hypr/voice/vosk-model-small-en-us-0.15")
COMMANDS_PATH = os.path.expanduser("~/.config/hypr/scripts/voice_commands.json")
VOICE_RATE = os.environ.get("VOICE_RATE", "170")
VOICE_NAME = os.environ.get("VOICE_NAME", "en")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
OPENAI_TTS_MODEL = os.environ.get("OPENAI_TTS_MODEL", "gpt-4o-mini-tts")
OPENAI_TTS_VOICE = os.environ.get("OPENAI_TTS_VOICE", "sage")
VOICE_TTS_PRE_DELAY_SECS = float(os.environ.get("VOICE_TTS_PRE_DELAY_SECS", "0.35"))
OPENAI_TTS_INSTRUCTIONS = os.environ.get(
    "OPENAI_TTS_INSTRUCTIONS",
    "Calm, low-energy, chill tone. Speak slightly slower, avoid hype, and speak in English only.",
)
OPENAI_STT_MODEL = os.environ.get("OPENAI_STT_MODEL", "whisper-1")
OPENAI_STT_LANGUAGE = os.environ.get("OPENAI_STT_LANGUAGE", "en").strip()
OPENAI_CHAT_MODEL = os.environ.get("OPENAI_CHAT_MODEL", "gpt-5.1")
USE_OPENAI_TTS = os.environ.get("VOICE_TTS", "").lower() == "openai"
USE_OPENAI_STT = os.environ.get("VOICE_STT", "").lower() == "openai"
LOG_PATH = os.environ.get("VOICE_LOG", "/tmp/voice_control.log")
DING_PATH = os.path.expanduser(os.environ.get("VOICE_DING", "~/Audio/ding.mp3"))
WAKE_WORD = os.environ.get("VOICE_WAKE_WORD", "yo").strip().lower()
REQUIRE_WAKE = os.environ.get("VOICE_REQUIRE_WAKE", "1").lower() not in ("0", "false", "no")
HISTORY_PATH = os.path.expanduser(os.environ.get("VOICE_HISTORY", "~/.config/hypr/voice/history.json"))
PLAYBACK_PID = os.environ.get("VOICE_PLAYBACK_PID", "/tmp/rudy_voice_playback.pid")
RUN_LOCK = os.environ.get("VOICE_RUN_LOCK", "/tmp/rudy_voice.lock")
COOLDOWN_PATH = os.environ.get("VOICE_COOLDOWN_PATH", "/tmp/rudy_voice_cooldown.json")
COOLDOWN_SECS = float(os.environ.get("VOICE_COOLDOWN_SECS", "1.5"))
SHOW_POPUP = os.environ.get("VOICE_POPUP", "1").lower() not in ("0", "false", "no")
EVENT_LOG_PATH = os.environ.get("VOICE_EVENT_LOG", "/tmp/voice_control_events.log")
LOG_LEVEL = os.environ.get("VOICE_LOG_LEVEL", "debug").lower()
VOICE_ENGLISH_ONLY = os.environ.get("VOICE_ENGLISH_ONLY", "1").lower() not in ("0", "false", "no")
ALLOW_COMMAND_PREFIX = os.environ.get("VOICE_COMMAND_PREFIX", "0").lower() in ("1", "true", "yes")
LEVEL_MAP = {"debug": 10, "info": 20, "warn": 30, "error": 40}
_RUN_LOCK_FD = None

try:
    from vosk import Model, KaldiRecognizer
except Exception:
    Model = None
    KaldiRecognizer = None

if not os.path.isfile(COMMANDS_PATH):
    print(f"Commands file missing: {COMMANDS_PATH}")
    sys.exit(1)

with open(COMMANDS_PATH, "r", encoding="utf-8") as f:
    _raw_commands = json.load(f)

def normalize(text: str) -> str:
    return text.strip().lower().strip(string.punctuation + " ")


def collapse_repeats(text: str) -> str:
    if not text:
        return text
    # If the STT repeats the same clause, keep only the first clause
    for sep in [",", ".", "?", "!", ";", ":"]:
        if sep in text:
            first = text.split(sep, 1)[0].strip()
            if first:
                text = first
            break
    # Collapse repeated words: "open open open" -> "open"
    parts = text.split()
    if not parts:
        return text
    collapsed = [parts[0]]
    for w in parts[1:]:
        if w != collapsed[-1]:
            collapsed.append(w)
    return " ".join(collapsed)


def normalize_wake(text: str) -> str:
    # Keep wake text literal; do not auto-map similar words.
    return text


def contains_cjk(text: str) -> bool:
    for ch in text:
        code = ord(ch)
        if (
            0x3040 <= code <= 0x30FF  # Hiragana + Katakana
            or 0x4E00 <= code <= 0x9FFF  # CJK Unified Ideographs
            or 0x3400 <= code <= 0x4DBF  # CJK Extension A
        ):
            return True
    return False


def is_safe_prefix_command(text: str, key: str) -> bool:
    if not ALLOW_COMMAND_PREFIX:
        return False
    if not text.startswith(key + " "):
        return False
    suffix = text[len(key):].strip().lower()
    return suffix in {"please", "now", "for me", "thanks", "thank you"}

COMMANDS = {normalize(k): v for k, v in _raw_commands.items()}


def _should_log(level: str) -> bool:
    current = LEVEL_MAP.get(LOG_LEVEL, 10)
    got = LEVEL_MAP.get(level.lower(), 20)
    return got >= current


def _safe(value: str) -> str:
    return str(value).replace("\n", " ").replace("|", "/")


def log_event(level: str, event: str, message: str = "", **fields) -> None:
    if not _should_log(level):
        return
    ts_ms = int(time.time() * 1000)
    iso = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    field_parts = [f"{k}={_safe(v)}" for k, v in fields.items()]
    fields_str = ";".join(field_parts)
    line = f"{ts_ms}|{iso}|{level.upper()}|python|{_safe(event)}|{_safe(message)}|{fields_str}\n"
    text_line = f"[{iso}] [{level.upper()}] [{event}] {message} {fields_str}\n"
    try:
        with open(EVENT_LOG_PATH, "a", encoding="utf-8") as ef:
            ef.write(line)
    except Exception:
        pass
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as lf:
            lf.write(text_line)
    except Exception:
        pass


def log(msg: str) -> None:
    log_event("info", "message", msg)


def acquire_run_lock() -> bool:
    global _RUN_LOCK_FD
    try:
        lock_fd = os.open(RUN_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _RUN_LOCK_FD = lock_fd
        log_event("debug", "run_lock_acquired", "Acquired python run lock", path=RUN_LOCK)
        return True
    except Exception:
        log_event("warn", "run_lock_busy", "Run lock busy, skipping invocation", path=RUN_LOCK)
        return False


def stop_playback() -> None:
    log_event("debug", "stop_playback", "Stopping existing playback processes")
    try:
        # Hard-stop any lingering playback
        subprocess.run(["pkill", "-f", "ffplay"], check=False)
        subprocess.run(["pkill", "-f", "mpv"], check=False)
        if os.path.isfile(PLAYBACK_PID):
            with open(PLAYBACK_PID, "r", encoding="utf-8") as f:
                pid = int(f.read().strip() or "0")
            if pid > 0:
                try:
                    os.kill(pid, 15)
                except Exception:
                    pass
    finally:
        try:
            os.unlink(PLAYBACK_PID)
        except Exception:
            pass


def speak_openai(text: str) -> None:
    if not OPENAI_API_KEY:
        log_event("error", "tts_missing_key", "OPENAI_API_KEY is missing")
        return
    if VOICE_ENGLISH_ONLY and contains_cjk(text):
        log_event("warn", "tts_non_english_blocked", "Blocked non-English TTS text")
        text = "Let's continue in English. Please repeat that in English."
    stop_playback()
    log_event("debug", "tts_request", "Requesting OpenAI TTS", model=OPENAI_TTS_MODEL, voice=OPENAI_TTS_VOICE)
    payload = {
        "model": OPENAI_TTS_MODEL,
        "input": text,
        "voice": OPENAI_TTS_VOICE,
        "response_format": "mp3",
    }
    if OPENAI_TTS_INSTRUCTIONS:
        payload["instructions"] = OPENAI_TTS_INSTRUCTIONS
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=data,
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=20) as resp:
            audio = resp.read()
    except (HTTPError, URLError) as e:
        log_event("error", "tts_request_failed", "OpenAI TTS request failed", error=str(e))
        return
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tf:
        tf.write(audio)
        audio_path = tf.name
    if VOICE_TTS_PRE_DELAY_SECS > 0:
        time.sleep(VOICE_TTS_PRE_DELAY_SECS)
    if shutil.which("mpv"):
        proc = subprocess.Popen(["mpv", "--no-video", "--really-quiet", audio_path])
    else:
        proc = subprocess.Popen(["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", audio_path])
    try:
        with open(PLAYBACK_PID, "w", encoding="utf-8") as f:
            f.write(str(proc.pid))
    except Exception:
        pass
    log_event("info", "tts_playback", "Playing assistant speech", pid=proc.pid, bytes=len(audio))
    proc.wait()
    try:
        os.unlink(audio_path)
    except OSError:
        pass


def speak(text: str) -> None:
    if not text:
        return
    if USE_OPENAI_TTS and OPENAI_API_KEY:
        speak_openai(text)
        return


def transcribe_openai(path: str) -> str:
    if not OPENAI_API_KEY:
        log_event("error", "stt_missing_key", "OPENAI_API_KEY is missing")
        return ""
    boundary = "----openai-voice-boundary"
    with open(path, "rb") as f:
        audio = f.read()
    parts = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="model"\r\n\r\n')
    parts.append(OPENAI_STT_MODEL.encode() + b"\r\n")
    if OPENAI_STT_LANGUAGE:
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(b'Content-Disposition: form-data; name="language"\r\n\r\n')
        parts.append(OPENAI_STT_LANGUAGE.encode() + b"\r\n")
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n')
    parts.append(b"Content-Type: audio/wav\r\n\r\n")
    parts.append(audio + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = request.Request(
        "https://api.openai.com/v1/audio/transcriptions",
        data=body,
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    log_event("debug", "stt_request", "Requesting OpenAI transcription", model=OPENAI_STT_MODEL, wav=path)
    try:
        with request.urlopen(req, timeout=30) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            text = res.get("text", "").strip().lower()
            log_event("info", "stt_response", "Received transcription", chars=len(text))
            return text
    except (HTTPError, URLError) as e:
        log_event("error", "stt_request_failed", "OpenAI STT request failed", error=str(e))
        return ""


def transcribe(path: str) -> str:
    if USE_OPENAI_STT and OPENAI_API_KEY:
        text = transcribe_openai(path)
        if text:
            return text
    if Model is None or KaldiRecognizer is None:
        return ""
    if not os.path.isdir(MODEL_PATH):
        return ""
    model = Model(MODEL_PATH)
    rec = KaldiRecognizer(model, 16000)
    with wave.open(path, "rb") as wf:
        while True:
            data = wf.readframes(4000)
            if len(data) == 0:
                break
            rec.AcceptWaveform(data)
    res = json.loads(rec.FinalResult())
    return res.get("text", "").strip().lower()


def send_paste(text: str) -> None:
    p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE)
    p.communicate(text.encode("utf-8"))
    subprocess.run(["hyprctl", "dispatch", "sendshortcut", "CTRL,V"], check=False)


def show_popup(text: str) -> None:
    if not SHOW_POPUP or not text:
        return
    msg = f"Heard: {text}"
    if shutil.which("hyprctl"):
        # hyprctl notify: type=1 (info), duration ms, color arg optional
        subprocess.Popen(["hyprctl", "notify", "1", "4000", "0", msg])
        log_event("debug", "popup_hyprctl", "Displayed transcript popup", chars=len(text))
        return
    if shutil.which("notify-send"):
        subprocess.Popen(["notify-send", "-a", "Rudy", "-t", "4000", msg])
        log_event("debug", "popup_notify_send", "Displayed transcript popup", chars=len(text))


def run_command(cmd: str) -> None:
    long_run = any(token in cmd for token in ["cargo run", "python", "uvicorn", "node ", "npm ", "pnpm ", "yarn "])
    log_event("info", "command_dispatch", "Dispatching command", command=cmd, long_run=long_run)
    if cmd.lstrip().startswith("kitty "):
        subprocess.Popen(["hyprctl", "dispatch", "exec", cmd])
        return
    if cmd.lstrip().startswith("hyprctl "):
        subprocess.Popen(["bash", "-lc", cmd])
        return
    if long_run:
        # Run in a terminal so it stays visible
        subprocess.Popen(["hyprctl", "dispatch", "exec", f"kitty -e bash -lc '{cmd}'"])
    else:
        subprocess.Popen(["bash", "-lc", cmd])

def cooldown_hit(key: str) -> bool:
    now = time.time()
    try:
        if os.path.isfile(COOLDOWN_PATH):
            with open(COOLDOWN_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            last_key = data.get("key")
            last_ts = float(data.get("ts", 0))
            if key == last_key and (now - last_ts) < COOLDOWN_SECS:
                return True
    except Exception:
        pass
    try:
        with open(COOLDOWN_PATH, "w", encoding="utf-8") as f:
            json.dump({"key": key, "ts": now}, f)
    except Exception:
        pass
    return False

def play_ding() -> None:
    if os.path.isfile(DING_PATH):
        stop_playback()
        if shutil.which("mpv"):
            proc = subprocess.Popen(["mpv", "--no-video", "--really-quiet", DING_PATH])
        else:
            proc = subprocess.Popen(["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", DING_PATH])
        try:
            with open(PLAYBACK_PID, "w", encoding="utf-8") as f:
                f.write(str(proc.pid))
        except Exception:
            pass
        log_event("debug", "ding_play", "Played command ding", pid=proc.pid, path=DING_PATH)

def get_weather(location: str) -> str:
    if not location:
        return ""
    try:
        url = f"https://wttr.in/{location}?format=3"
        out = subprocess.check_output(["curl", "-s", url], text=True, timeout=8)
        log_event("info", "weather_query", "Fetched weather", location=location)
        return out.strip()
    except Exception as e:
        log_event("error", "weather_error", "Weather lookup failed", location=location, error=str(e))
        return ""

def load_history():
    if not os.path.isfile(HISTORY_PATH):
        return []
    try:
        with open(HISTORY_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []

def save_history(history):
    os.makedirs(os.path.dirname(HISTORY_PATH), exist_ok=True)
    try:
        with open(HISTORY_PATH, "w", encoding="utf-8") as f:
            json.dump(history[-30:], f, ensure_ascii=False, indent=2)
    except Exception:
        pass

def chat_openai(user_text: str, history) -> str:
    if not OPENAI_API_KEY:
        return ""
    messages = [{
        "role": "system",
        "content": (
            "You are Codex, a pragmatic voice coding and desktop assistant on Linux. "
            "You help with coding tasks, shell commands, debugging, and quick desktop actions. "
            "Be concise, direct, and actionable. "
            "Prefer short answers unless the user asks for detail. "
            "Respond in English only."
        )
    }]
    messages.extend(history[-20:])
    messages.append({"role": "user", "content": user_text})
    payload = {
        "model": OPENAI_CHAT_MODEL,
        "input": messages,
    }
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(
        "https://api.openai.com/v1/responses",
        data=data,
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    log_event("debug", "chat_request", "Requesting assistant chat response", model=OPENAI_CHAT_MODEL)
    try:
        with request.urlopen(req, timeout=30) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            # Responses API text output
            out = res.get("output", [])
            text_parts = []
            for item in out:
                for c in item.get("content", []):
                    if c.get("type") == "output_text":
                        text_parts.append(c.get("text", ""))
            reply = " ".join(text_parts).strip()
            if VOICE_ENGLISH_ONLY and contains_cjk(reply):
                log_event("warn", "chat_non_english_blocked", "Model reply contained non-English text; replaced")
                reply = "Let's continue in English. Please repeat that in English."
            log_event("info", "chat_response", "Received chat response", chars=len(reply))
            return reply
    except (HTTPError, URLError) as e:
        log_event("error", "chat_request_failed", "OpenAI chat request failed", error=str(e))
        return ""


def main() -> None:
    if not acquire_run_lock():
        return
    log_event("info", "main_start", "voice_control.py started")
    if len(sys.argv) < 2:
        print("Usage: voice_control.py <wav_path>")
        sys.exit(1)
    wav_path = sys.argv[1]
    if not os.path.isfile(wav_path):
        log_event("error", "wav_missing", "WAV file not found", wav=wav_path)
        return
    try:
        wav_size = os.path.getsize(wav_path)
        log_event("info", "wav_ready", "WAV ready for STT", bytes=wav_size, wav=wav_path)
    except Exception:
        pass
    log_event("debug", "stt_mode", "STT mode and key state", use_openai_stt=USE_OPENAI_STT, api_key=("set" if OPENAI_API_KEY else "missing"))

    raw_text = normalize(transcribe(wav_path))
    log_event("info", "transcribe_raw", "Transcription result (raw)", text=raw_text)
    text = collapse_repeats(normalize_wake(raw_text))
    if text != raw_text:
        log_event("debug", "transcribe_collapsed", "Collapsed repeated transcription", text=text)
    show_popup(text)
    if not text:
        speak("Sorry, I missed that. Try again.")
        log_event("warn", "empty_transcript", "Transcript was empty")
        return

    # Wake word handling
    if WAKE_WORD:
        if text.startswith(WAKE_WORD + " "):
            text = text[len(WAKE_WORD) + 1 :].strip()
        elif text == WAKE_WORD:
            log_event("info", "wake_word_only", "Wake word detected without intent; ignored")
            return
        elif REQUIRE_WAKE:
            log_event("info", "wake_word_missing", "Wake word not detected; ignoring transcript")
            return

    # dictation
    if text.startswith("type "):
        payload = text[5:]
        send_paste(payload)
        speak("Typed.")
        log_event("info", "dictation_type", "Handled type command", chars=len(payload))
        return
    if text.startswith("dictate "):
        payload = text[8:]
        send_paste(payload)
        speak("Dictated.")
        log_event("info", "dictation_dictate", "Handled dictate command", chars=len(payload))
        return

    # weather queries
    if text.startswith("weather in "):
        loc = text[len("weather in "):].strip()
        weather = get_weather(loc)
        if weather:
            speak(weather)
        else:
            speak("Sorry, I couldn't get the forecast.")
        return
    if text.startswith("weather for "):
        loc = text[len("weather for "):].strip()
        weather = get_weather(loc)
        if weather:
            speak(weather)
        else:
            speak("Sorry, I couldn't get the forecast.")
        return

    # command match (exact or prefix)
    if text in COMMANDS:
        if not cooldown_hit(text):
            play_ding()
            run_command(COMMANDS[text])
            log_event("info", "command_matched", "Matched command (exact)", key=text)
        return
    for k, v in COMMANDS.items():
        if is_safe_prefix_command(text, k):
            if not cooldown_hit(k):
                play_ding()
                run_command(v)
                log_event("info", "command_matched_prefix", "Matched command (safe prefix)", key=k, transcript=text)
            return

    # agentic chatbot fallback
    history = load_history()
    reply = chat_openai(text, history)
    if reply:
        history.append({"role": "user", "content": text})
        history.append({"role": "assistant", "content": reply})
        save_history(history)
        send_paste(reply)
        speak(reply)
        log_event("info", "chat_reply_spoken", "Spoke assistant reply", chars=len(reply))
        return

    # fallback: acknowledge without pasting
    speak(f"Yes. I heard: {text}.")
    log_event("warn", "fallback_ack", "Used fallback acknowledge", transcript=text)


if __name__ == "__main__":
    main()
