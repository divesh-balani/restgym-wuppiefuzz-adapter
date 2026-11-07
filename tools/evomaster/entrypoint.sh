#!/bin/sh
# RESTgym entrypoint for EvoMaster (black-box).
# Vendored from restgym/evomaster-tool@e110365 and patched: the original hard-coded
# --maxTime 1h, so with shorter RESTgym budgets EvoMaster was killed mid-search
# (e.g. 25% of its budget at TIME_BUDGET=15). Now the search budget follows TIME_BUDGET.

log() { echo "[evomaster-wrapper] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2; }

ls /specifications

# RESTgym stops the container TIME_BUDGET minutes after start. Leave 60 s for
# EvoMaster's post-search phases (minimisation, test writing).
BUDGET_S=$(( ${TIME_BUDGET:-60} * 60 ))
SEARCH_S=$(( BUDGET_S - 60 ))
[ "$SEARCH_S" -lt 60 ] && SEARCH_S=60
log "API=$API TARGET=http://${HOST}:${PORT} TIME_BUDGET=${TIME_BUDGET:-unset} search=${SEARCH_S}s"

START=$(date +%s)
RESTARTS=0
while :; do
  REMAINING=$(( SEARCH_S - ($(date +%s) - START) ))
  [ "$REMAINING" -lt 30 ] && break
  java -jar /evomaster.jar \
    --runningInDocker true \
    --blackBox true \
    --maxTime "${REMAINING}s" \
    --bbSwaggerUrl "/specifications/${API}-openapi.json" \
    --bbTargetUrl "http://${HOST}:${PORT}"
  CODE=$?
  if [ "$CODE" -eq 0 ]; then
    log "search finished (exit 0) after $(( $(date +%s) - START ))s"
    break
  fi
  RESTARTS=$(( RESTARTS + 1 ))
  log "RESTART $RESTARTS: EvoMaster exited with code $CODE, restarting in 5s"
  sleep 5
done

log "done: restarts=$RESTARTS"
# RESTgym treats an exited tool container as a failure, so stay alive until stopped.
trap 'exit 0' TERM INT
while :; do sleep 1; done
