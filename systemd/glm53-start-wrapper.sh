#!/usr/bin/env bash
# glm53-start-wrapper.sh — systemd ExecStart for the GLM-5.3-Flash TP=2 pair.
# Removes stale glm53a-r0/r1 containers (preflight_runtime.py refuses to serve
# onto existing container names), then runs the knapcio start_tp2.sh serve
# sequence (worker rank 1 first, head rank 0 second) using the preflight-written
# env.runtime (base profile + freshly probed RoCEv2 GID). Then WAITS for
# /health 200 + engine-ready log line before returning, so RemainAfterExit=yes
# maps to a genuinely serving pair. If health never turns green, exits 1 so
# systemd leaves the unit failed (Restart=no) for manual inspection.
set -uo pipefail

KNAP=/home/sakkout/glm53-knapcio
ENV_RUNTIME="$KNAP/env.runtime"
PORT="${GLM53_PORT:-8000}"
CTN="${GLM53_CTN:-glm53a}"
WORKER="spark-8485"
SERVED="${GLM53_SERVED_NAME:-glm-5.3-flash}"
LOGTAG="glm53-start"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/glm53-watchdog"
mkdir -p "$STATE_DIR"

log() { echo "[$LOGTAG] $*"; logger -t "$LOGTAG" "$*" 2>/dev/null || true; }

[ -f "$ENV_RUNTIME" ] || { log "FATAL: $ENV_RUNTIME missing — preflight must run first"; exit 1; }

# --- 1. Tear down stale containers (whole-pair, both nodes) ---
# The launcher's preflight_runtime.py refuses to serve onto an existing
# container name, and a stale worker wedges the new head's TCPStore rendezvous.
for c in r0; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CTN}-$c$"; then
    log "removing stale head container ${CTN}-$c"
    docker rm -f "${CTN}-$c" >/dev/null 2>&1 || true
  fi
done
if ssh -o ConnectTimeout=10 -o BatchMode=yes "$WORKER" "docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^${CTN}-r1$'"; then
  log "removing stale worker container ${CTN}-r1 on $WORKER"
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$WORKER" "docker rm -f ${CTN}-r1" >/dev/null 2>&1 || true
fi
sleep 10  # master-port TIME_WAIT / NVRM settle (playbook's POST_TEARDOWN_SLEEP)

# --- 2. Launch: worker first, then head, with the probed GID ---
cd "$KNAP"
if ENV_FILE="$ENV_RUNTIME" bash start_tp2.sh serve >>"$STATE_DIR/start.log" 2>&1; then
  log "start_tp2.sh serve returned 0"
else
  rc=$?
  log "FATAL: start_tp2.sh serve exited $rc — see $STATE_DIR/start.log"
  exit 1
fi

# --- 3. Wait for genuine readiness: /health 200 AND engine alive ---
# /v1/models can return 200 with a dead engine (playbook warning); use /health.
HEALTH="http://127.0.0.1:${PORT}/health"
log "waiting for $HEALTH (engine load 3.6-10 min; timeout 1800s)"
waited=0
while :; do
  if curl -fsS -m 8 "$HEALTH" >/dev/null 2>&1; then
    log "health is 200 after ${waited}s"
    break
  fi
  sleep 15
  waited=$((waited+15))
  if [ "$waited" -ge 1800 ]; then
    log "FATAL: /health not 200 within 1800s — leaving unit failed for inspection"
    exit 1
  fi
done

# --- 4. Real chat completion through the live API (engine proof) ---
ok=0
for attempt in 1 2 3; do
  reply=$(curl -fsS -m 90 http://127.0.0.1:${PORT}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$SERVED\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":96}") || { sleep 10; continue; }
  content=$(printf '%s' "$reply" | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["choices"][0]["message"]; print((c.get("content") or "").strip())' 2>/dev/null)
  if [ -n "$content" ]; then
    log "engine verified by real chat completion (attempt $attempt): $content"
    ok=1; break
  fi
  sleep 10
done
[ "$ok" = 1 ] || { log "FATAL: no chat completion after health-200 (engine may be dead) — see $STATE_DIR/start.log"; exit 1; }

log "GLM-5.3-Flash pair is up and verified on :${PORT}"
exit 0