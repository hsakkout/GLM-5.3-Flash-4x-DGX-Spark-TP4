# GLM-5.3-Flash production supervision (2026-10-13)

GLM-5.3-Flash TP=2 (knapcio stack, `~/glm53-knapcio/`, containers `glm53a-r0/r1`) is the
primary local service on `http://127.0.0.1:8000/v1`, served model `glm-5.3-flash`,
**262,144-token context** (the 2x-Spark playbook setting — 1M is the 4-Spark TP4 lane;
1M-context TP2 variants starved the KV pool and crashed the fleet 3x on 2026-09-01, per
tonyd2wild `CURRENT.md`: "Do not raise --max-model-len on TP2"). DS4 is deprecated as the
daily service and is retained as an emergency-only deployment.

## Units (user systemd, Node 1)

- `glm53-flash.service` — `Type=oneshot, RemainAfterExit=yes, TimeoutStartSec=2700`,
  `Restart=no`. ExecStartPre: stops llama-server; runs `systemd/glm53-preflight.sh`
  (probes BOTH nodes each launch: ssh, swappiness=0, RoCEv2 GID — writes
  `env.runtime` = `env.tp2-low` + freshly probed GID, ports, image, weights,
  llama-off, DS4-not-coserving). ExecStart: `systemd/glm53-start-wrapper.sh`
  (docker rm stale containers, worker-first `start_tp2.sh serve` with `ENV_FILE=env.runtime`,
  waits `/health` 200, then a real chat completion — engine proof, not just API surface).
  ExecStop: `systemd/glm53-stop-wrapper.sh` (preserving stop, both nodes).
- `glm53-watchdog.service` + `.timer` — every 2 min, probes **`/health`** (NOT
  `/v1/models` — that returns 200 with a dead engine; playbook warning). 3 consecutive
  failures → `systemctl --user restart glm53-flash` (whole-pair restart via the unit,
  worker-first). Stands down while the unit is activating. Same memory-pressure state
  machine as DS4 (CLEAR→ALERT→REMINDER→ALLCLEAR, warn <6 GiB, alert <5 GiB).
  Log: `~/.local/state/glm53-watchdog/watchdog.log`.
- Telegram relay: `~/.hermes/scripts/glm53-alert-relay.sh` (no_agent cron, every 3 min,
  byte-offset dedup) carries `ALERT | REMINDER | ALLCLEAR | RESTART` lines — restart
  transitions are alert-class (DS4's restart-failure loops were silent; fixed here).

## Emergency: activate DS4

1. `systemctl --user stop glm53-flash.service` — stop wrapper tears down BOTH nodes.
2. `systemctl --user disable glm53-watchdog.timer` (stop alone leaves it boot-enabled).
3. Launch DS4 per its recipe (`~/ds4-0731-recipe/`); its units remain on disk,
   disabled, and the `ds4-spark` provider def stays in Hermes configs (unreferenced).

## Hermes wiring (both profiles verified 2026-10-13)

- **Main (Miranda):** primary `ollama-cloud/glm-5.3`; fallback #1 `custom:glm53-flash`
  (local); then openrouter kimi-k3. DS4 removed from all references.
- **Sandbox (Amira):** primary `custom:glm53-flash` (local); fallback #1
  `ollama-cloud/glm-5.3`; then openrouter kimi-k3. Top-level `context_length: 1000000`
  (governs cloud fallbacks); per-model override `262144` governs the local primary.
- `~/.pi/agent/models.json`: `local-glm53` provider added (`:8000/v1`, 262144);
  `local-dspark` retained for emergencies.

## Operational rules

- Never docker-restart a single container of the pair (half-pair doom loop) —
  always `systemctl --user restart glm53-flash`.
- After any kernel/driver update on either node: preflight re-probes the GID
  automatically at the next launch; no pins anywhere (GID lesson).
- `sudo sysctl vm.swappiness=0` on BOTH nodes after every reboot (resets to 60;
  not persisted in sysctl.d — add it there when sudo is next available).
- Maintenance takedown: stop the service unit, THEN `systemctl --user disable
  glm53-watchdog.timer` (watchdog restarts the pair every ~6 min otherwise).