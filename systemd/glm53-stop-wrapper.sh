#!/usr/bin/env bash
# glm53-stop-wrapper.sh — systemd ExecStop for the GLM-5.3-Flash TP=2 pair.
# Uses the launcher's own preserving stop (worker first, then head), so
# FlashInfer/TRITON caches and any running boot-warm helper die with it.
set -uo pipefail

KNAP=/home/sakkout/glm53-knapcio
ENV_RUNTIME="$KNAP/env.runtime"
CTN="${GLM53_CTN:-glm53a}"
WORKER="spark-8485"
LOGTAG="glm53-stop"

log() { echo "[$LOGTAG] $*"; logger -t "$LOGTAG" "$*" 2>/dev/null || true; }

cd "$KNAP"
if [ -f "$ENV_RUNTIME" ]; then
  ENV_FILE="$ENV_RUNTIME" bash start_tp2.sh stop >>"${XDG_STATE_HOME:-$HOME/.local/state}/glm53-watchdog/stop.log" 2>&1 && log "stop_tp2 sequence complete (both containers preserved-stopped)" || log "WARN: start_tp2 stop reported failure (continuing — containers may already be gone)"
else
  # Fallback: direct docker stop on both nodes (preserving the container for inspection)
  docker stop --time 30 "${CTN}-r0" >/dev/null 2>&1 || true
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$WORKER" "docker stop --time 30 ${CTN}-r1" >/dev/null 2>&1 || true
  log "fallback docker stop executed on both nodes"
fi
exit 0