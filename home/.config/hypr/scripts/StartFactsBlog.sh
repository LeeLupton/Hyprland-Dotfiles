#!/usr/bin/env bash
# Start Facts.blog dev server for Waybar news ribbon at login.

set -u

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
LOG_FILE="$LOG_DIR/facts-blog-dev.log"
PID_FILE="$LOG_DIR/facts-blog-dev.pid"
mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

resolve_facts_dir() {
  local candidates=(
    "${FACTS_BLOG_DIR:-}"
    "$HOME/Facts.blog"
  )
  local d
  for d in "${candidates[@]}"; do
    [[ -n "$d" ]] || continue
    if [[ -f "$d/package.json" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

running_facts_dev() {
  if pgrep -af "server/index.ts" | grep -F "$FACTS_DIR" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ps -p "$pid" -o args= 2>/dev/null | grep -Fq "npm run dev"; then
      return 0
    fi
  fi

  return 1
}

FACTS_DIR="$(resolve_facts_dir || true)"
if [[ -z "${FACTS_DIR:-}" ]]; then
  log "Facts.blog not found (set FACTS_BLOG_DIR or use \$HOME/Facts.blog); skipping."
  exit 0
fi

if running_facts_dev; then
  log "Facts.blog dev server already running; skipping duplicate start."
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  log "npm not found; cannot start Facts.blog dev server."
  exit 0
fi

if ! grep -Eq '"dev"\s*:' "$FACTS_DIR/package.json"; then
  log "No dev script in $FACTS_DIR/package.json; skipping."
  exit 0
fi

if [[ ! -d "$FACTS_DIR/node_modules" ]]; then
  log "node_modules missing in $FACTS_DIR; installing dependencies."
  if [[ -f "$FACTS_DIR/package-lock.json" ]]; then
    (cd "$FACTS_DIR" && npm ci --no-audit --no-fund) >>"$LOG_FILE" 2>&1 || {
      log "npm ci failed; aborting startup."
      exit 0
    }
  else
    (cd "$FACTS_DIR" && npm install --no-audit --no-fund) >>"$LOG_FILE" 2>&1 || {
      log "npm install failed; aborting startup."
      exit 0
    }
  fi
fi

log "Starting Facts.blog dev server from $FACTS_DIR"
(
  cd "$FACTS_DIR" || exit 0
  nohup npm run dev >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
) || true

sleep 1
if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE" 2>/dev/null || echo 0)" >/dev/null 2>&1; then
  log "Facts.blog dev server started successfully (pid $(cat "$PID_FILE"))."
else
  log "Facts.blog dev server did not stay running; check log output."
fi

exit 0
