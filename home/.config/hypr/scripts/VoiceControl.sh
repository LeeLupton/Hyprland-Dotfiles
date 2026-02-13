#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PID_FILE="$RUNTIME_DIR/voice_control_ffmpeg.pid"
WAV_FILE="$RUNTIME_DIR/voice_control.wav"
LOCK_FILE="$RUNTIME_DIR/voice_control.lock"
MAX_WAV_BYTES="${VOICE_MAX_WAV_BYTES:-8000000}"
STALE_SECONDS="${VOICE_STALE_SECONDS:-120}"
RECORD_START_SOUND="${VOICE_RECORD_START_SOUND:-$HOME/Audio/nintendo-ds-startup.mp3}"
LOG_PATH="${VOICE_LOG:-/tmp/voice_control.log}"
EVENT_LOG_PATH="${VOICE_EVENT_LOG:-/tmp/voice_control_events.log}"
LOG_LEVEL="${VOICE_LOG_LEVEL:-debug}"

VENV="$HOME/.config/hypr/voice/venv"
PY="$VENV/bin/python"
SCRIPT="$HOME/.config/hypr/scripts/voice_control.py"

level_to_num() {
  case "${1,,}" in
    debug) echo 10 ;;
    info) echo 20 ;;
    warn) echo 30 ;;
    error) echo 40 ;;
    *) echo 20 ;;
  esac
}

sanitize() {
  local val="${1//$'\n'/ }"
  val="${val//|//}"
  echo "$val"
}

log_event() {
  local level="$1"
  local event="$2"
  local message="${3:-}"
  shift 3 || true

  local wanted
  local got
  wanted=$(level_to_num "$LOG_LEVEL")
  got=$(level_to_num "$level")
  if (( got < wanted )); then
    return
  fi

  local ts_ms
  local iso
  ts_ms=$(date +%s%3N 2>/dev/null || echo "$(( $(date +%s) * 1000 ))")
  iso=$(date -Iseconds)

  local fields=""
  local kv
  for kv in "$@"; do
    kv="$(sanitize "$kv")"
    if [[ -n "$fields" ]]; then
      fields="${fields};"
    fi
    fields="${fields}${kv}"
  done

  local safe_msg
  safe_msg="$(sanitize "$message")"
  echo "[$iso] [${level^^}] [$event] $safe_msg $fields" >> "$LOG_PATH"
  echo "${ts_ms}|${iso}|${level^^}|shell|${event}|${safe_msg}|${fields}" >> "$EVENT_LOG_PATH"
}

# Load API key if present
if [[ -f "$HOME/.env" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.env"
  # ensure exported for child process
  export OPENAI_API_KEY
fi

# Fallback parse if not set
if [[ -z "${OPENAI_API_KEY:-}" && -f "$HOME/.env" ]]; then
  OPENAI_API_KEY=$(grep -E '^OPENAI_API_KEY=' "$HOME/.env" | head -n1 | cut -d= -f2- | tr -d '"')
  export OPENAI_API_KEY
fi

if [[ ! -x "$PY" ]]; then
  echo "Voice venv missing. Create it: python3 -m venv $VENV" >&2
  log_event error "venv_missing" "Voice venv missing" "path=$VENV"
  exit 1
fi

# Toggle behavior: first press starts recording, second press stops and transcribes
log_event info "invoked" "VoiceControl hotkey invoked" "pid=$$"
rm -f "$LOCK_FILE" 2>/dev/null || true

start_new_recording=0
if [[ -f "$PID_FILE" ]]; then
  log_event debug "pid_file_found" "PID file exists" "file=$PID_FILE"
  pid=$(cat "$PID_FILE" || true)
  if [[ -n "$pid" ]]; then
    if ps -p "$pid" >/dev/null 2>&1; then
      log_event info "stop_recording" "Stopping active recording" "pid=$pid"
      # kill stale or oversized recordings
      if [[ -f "$WAV_FILE" ]]; then
        wav_size=$(stat -c %s "$WAV_FILE" 2>/dev/null || echo 0)
        wav_mtime=$(stat -c %Y "$WAV_FILE" 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        log_event debug "wav_state" "Current wav state" "size_bytes=$wav_size" "mtime=$wav_mtime"
        if [[ "$wav_size" -ge "$MAX_WAV_BYTES" ]] || [[ $((now_ts - wav_mtime)) -ge "$STALE_SECONDS" ]]; then
          kill -INT "$pid" 2>/dev/null || true
          pkill -f "pw-record.*voice_control.wav" >/dev/null 2>&1 || true
          pkill -f "ffmpeg.*voice_control.wav" >/dev/null 2>&1 || true
          rm -f "$PID_FILE"
          log_event warn "forced_stop" "Forced stop due to stale/oversize wav" "pid=$pid"
          exec env VOICE_EVENT_LOG="$EVENT_LOG_PATH" VOICE_LOG_LEVEL="$LOG_LEVEL" "$PY" "$SCRIPT" "$WAV_FILE"
        fi
      fi
      kill -INT "$pid" 2>/dev/null || true
      pkill -f "pw-record.*voice_control.wav" >/dev/null 2>&1 || true
      pkill -f "ffmpeg.*voice_control.wav" >/dev/null 2>&1 || true
      # wait for ffmpeg to flush file
      for _ in {1..20}; do
        if [[ -s "$WAV_FILE" ]]; then
          break
        fi
        sleep 0.1
      done
      rm -f "$PID_FILE"
      log_event info "handoff_transcribe" "Handing off wav for transcription" "wav=$WAV_FILE"
      exec env VOICE_EVENT_LOG="$EVENT_LOG_PATH" VOICE_LOG_LEVEL="$LOG_LEVEL" "$PY" "$SCRIPT" "$WAV_FILE"
    else
      log_event warn "stale_pid" "Stale pid file found" "pid=$pid"
      rm -f "$PID_FILE"
      start_new_recording=1
    fi
  else
    log_event warn "empty_pid_file" "PID file empty"
    rm -f "$PID_FILE"
    start_new_recording=1
  fi
else
  start_new_recording=1
fi

if [[ "$start_new_recording" -eq 1 ]]; then
  # Start recording (no duration; stopped on next press)
  log_event info "start_recording" "Starting audio capture" "wav=$WAV_FILE"
  rm -f "$WAV_FILE"
  SRC="${VOICE_SOURCE:-default}"
  if [[ -f "$RECORD_START_SOUND" ]]; then
    if command -v mpv >/dev/null 2>&1; then
      mpv --no-video --really-quiet "$RECORD_START_SOUND" >/dev/null 2>&1 & disown || true
    else
      ffplay -nodisp -autoexit -loglevel quiet "$RECORD_START_SOUND" </dev/null & disown || true
    fi
    log_event debug "record_sound" "Played record-start sound" "path=$RECORD_START_SOUND"
  fi

  backend="ffmpeg"
  if command -v pw-record >/dev/null 2>&1; then
    backend="pw-record"
    pw-record --rate 16000 --channels 1 "$WAV_FILE" >/dev/null 2>&1 &
  else
    ffmpeg -f pulse -i "$SRC" -ac 1 -ar 16000 -y -loglevel quiet "$WAV_FILE" </dev/null &
  fi
  rec_pid=$!
  echo "$rec_pid" > "$PID_FILE"
  log_event info "recorder_started" "Recorder process launched" "pid=$rec_pid" "backend=$backend" "source=$SRC"
else
  log_event debug "noop" "No action taken after pid-file evaluation"
fi
