#!/bin/sh
# Keeps the configured models pulled into Ollama, beside it in the pod.
# Every pass asks Ollama which models it has and pulls the missing ones;
# nothing is ever deleted, so a model dropped from the list stays until
# someone removes it. A pull that fails (no network, a typo in the name)
# is retried on the next pass.
#
# Env: MODELS ("name:tag ..."), OLLAMA_HOST, RECONCILE_SECONDS
set -u
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

until ollama list >/dev/null 2>&1; do
  log "waiting for Ollama"
  sleep 3
done
while :; do
  have=$(ollama list 2>/dev/null | awk 'NR > 1 { print $1 }')
  for model in $MODELS; do
    case "$model" in *:*) want=$model ;; *) want=$model:latest ;; esac
    if printf '%s\n' "$have" | grep -qx "$want"; then
      continue
    fi
    log "pulling $want"
    if ollama pull "$want" >/tmp/pull.log 2>&1; then
      log "pulled $want"
    else
      log "pulling $want failed: $(tail -n 1 /tmp/pull.log)"
    fi
  done
  sleep "${RECONCILE_SECONDS:-600}"
done
