#!/usr/bin/env bash
# glm53-watchdog.sh — GLM-5.3-Flash TP=2 pair watchdog, driven by
# glm53-watchdog.timer every 2 min on Node 1. Mirrors the DS4 watchdog with
# three GLM-specific corrections:
#   1. Probes /health (NOT /v1/models — that returns 200 with a dead engine).
#   2. RESTART transitions are logged as ALERT-class lines so the Telegram
#      relay carries them (DS4's restart-failure loops were silent).
#   3. Stands down while glm53-flash.service is activating (load takes 3.6-10 min).
set -uo pipefail

UNIT="glm53-flash.service"
API="http://127.0.0.1:8000/health"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/glm53-watchdog"
FAIL_FILE="$STATE_DIR/consecutive_failures"
LOG_FILE="$STATE_DIR/watchdog.log"
THRESHOLD=3
WORKER="spark-8485"

mkdir -p "$STATE_DIR"
log() { echo "$(date -Is) $*" >> "$LOG_FILE"; }

# --- Never interfere with an in-flight start/stop ---
state=$(systemctl --user is-active "$UNIT" 2>/dev/null || true)
substate=$(systemctl --user show "$UNIT" -p SubState --value 2>/dev/null || true)
if [ "$state" = "activating" ] || [ "$substate" = "auto-restart" ]; then
  log "unit activating — watchdog standing down"
  exit 0
fi

# --- Only supervise when the unit is enabled ---
if ! systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
  # 2026-10-13 lesson: a manager-death churn once DROPPED the wants symlink;
  # the unit stayed down for an hour with the watchdog silently standing down.
  # Never silent again: if disabled AND the API is actually down, say so loudly.
  if curl -fsS -m 8 "$API" >/dev/null 2>&1; then
    echo 0 > "$FAIL_FILE"
    exit 0   # disabled but serving (maintenance pattern) — fine, stay quiet
  fi
  log "ALERT unit DISABLED and API DOWN ($API) — service is down and nothing will auto-start it. Re-enable+start: systemctl --user enable --now $UNIT"
  echo 0 > "$FAIL_FILE"
  exit 0
fi

# --- Memory guard: llama-server must not coexist (GB10 unified memory) ---
if systemctl --user is-active llama-server >/dev/null 2>&1; then
  log "llama-server active alongside GLM — stopping it (memory guard)"
  systemctl --user stop llama-server >> "$LOG_FILE" 2>&1 || true
fi

# --- Memory pressure tracking — GLM-TP2 calibration (2026-10-13).
#     At GPU_UTIL=0.83 with desktop co-residents, steady-state MemAvailable is
#     ~0.5 GiB BY DESIGN (env.tp2-low: 0.85 failed the free-memory gate on a
#     non-dedicated host; 0.83 + 4GiB KV is the documented tradeoff). Integer-GiB
#     thresholds (DS4's <6/<5) read 0 forever here — track MiB:
#     warn < 400 MiB (below the observed steady band), distress < 256 MiB
#     (genuine pre-OOM) or swap grew >1 GiB/tick (reclaim churn — the real
#     crash predictor per the DS4 stress-test work; static swap is benign). ---
AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
SWAP_USED_KB=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
AVAIL_MIB=$((AVAIL_KB/1024)); SWAP_GIB=$(( (SWAP_USED_KB/1024 + 1023)/1024 ))
SWAP_PREV_FILE="$STATE_DIR/swap_kb_prev"
swap_prev=$(cat "$SWAP_PREV_FILE" 2>/dev/null || echo "$SWAP_USED_KB")
echo "$SWAP_USED_KB" > "$SWAP_PREV_FILE"
swap_delta_gib=$(( (SWAP_USED_KB - swap_prev) / 1048576 ))
[ "$AVAIL_MIB" -lt 400 ] && log "MEMWARN MemAvailable=${AVAIL_MIB}MiB (<400) swap_used=${SWAP_GIB}GiB — below GLM steady band (~550MiB)"
[ "$swap_delta_gib" -gt 1 ] && log "MEMWARN swap grew +${swap_delta_gib}GiB since last tick (total ${SWAP_GIB}GiB) — likely reclaim churn"

# --- Memory pressure state machine (CLEAR -> ALERT -> REMINDER -> ALLCLEAR) ---
WARN_STREAK_FILE="$STATE_DIR/memwarn_streak"
MEM_STATE_FILE="$STATE_DIR/mem_alert_state"
MEM_ALERT_TS_FILE="$STATE_DIR/mem_alert_ts"
MEM_LAST_REMINDER_FILE="$STATE_DIR/mem_last_reminder"
in_distress=0
[ "$AVAIL_MIB" -lt 256 ] && in_distress=1
[ "$swap_delta_gib" -gt 1 ] && in_distress=1
if [ "$in_distress" = "1" ]; then
  streak=$(( $(cat "$WARN_STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$streak" > "$WARN_STREAK_FILE"
  mem_state=$(cat "$MEM_STATE_FILE" 2>/dev/null || echo clear)
  alert_ts=$(cat "$MEM_ALERT_TS_FILE" 2>/dev/null || echo 0)
  if [ "$streak" -ge 5 ]; then
    if [ "$mem_state" = "clear" ]; then
      now=$(date +%s)
      echo alert > "$MEM_STATE_FILE"; echo "$now" > "$MEM_ALERT_TS_FILE"; echo "$now" > "$MEM_LAST_REMINDER_FILE"
      log "ALERT memory pressure onset: MemAvailable=${AVAIL_MIB}MiB swap=${SWAP_GIB}GiB (streak=$streak)"
    else
      last_reminder=$(cat "$MEM_LAST_REMINDER_FILE" 2>/dev/null || echo 0); now=$(date +%s)
      if [ $(( (now - last_reminder) / 3600 )) -ge 24 ]; then
        echo "$now" > "$MEM_LAST_REMINDER_FILE"
        log "REMINDER memory pressure sustained $(( (now - (cat "$MEM_ALERT_TS_FILE" 2>/dev/null || echo 0)) / 3600 ))h: MemAvailable=${AVAIL_MIB}MiB swap=${SWAP_GIB}GiB"
      fi
    fi
  fi
else
  echo 0 > "$WARN_STREAK_FILE"
  mem_state=$(cat "$MEM_STATE_FILE" 2>/dev/null || echo clear)
  if [ "$mem_state" = "alert" ]; then
    alert_ts=$(cat "$MEM_ALERT_TS_FILE" 2>/dev/null || echo 0); now=$(date +%s)
    echo clear > "$MEM_STATE_FILE"
    log "ALLCLEAR memory pressure resolved after $(( (now - alert_ts) / 3600 ))h. MemAvailable=${AVAIL_MIB}MiB swap=${SWAP_GIB}GiB"
  fi
fi

# --- Health probe: /health gives 503 on EngineDeadError ---
if curl -fsS -m 8 "$API" >/dev/null 2>&1; then
  prev=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
  [ "$prev" != "0" ] && log "API healthy again (was $prev consecutive failures)"
  echo 0 > "$FAIL_FILE"
  exit 0
fi

fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$FAIL_FILE"
log "health probe FAILED ($fails/$THRESHOLD) — $API"
[ "$fails" -lt "$THRESHOLD" ] && exit 0

# --- Threshold reached: restart the PAIR via the service unit ---
head_age=$(docker inspect glm53a-r0 --format '{{.State.StartedAt}}' 2>/dev/null || echo none)
worker_age=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$WORKER" "docker inspect glm53a-r1 --format '{{.State.StartedAt}}'" 2>/dev/null || echo none)
log "ALERT restart triggered: 3 consecutive health failures. head_started=$head_age worker_started=$worker_age"
echo 0 > "$FAIL_FILE"
if systemctl --user restart "$UNIT" >> "$LOG_FILE" 2>&1; then
  log "RESTART pair restart issued OK (engine verification inside start wrapper)"
else
  log "ALERT pair restart FAILED — manual intervention needed"
fi