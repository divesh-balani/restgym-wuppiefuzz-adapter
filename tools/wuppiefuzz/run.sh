#!/bin/sh
# RESTgym entrypoint for WuppieFuzz (https://github.com/TNO-S3/WuppieFuzz).
# Env vars set by RESTgym: API, HOST, PORT, TIME_BUDGET (minutes).

log() { echo "[wuppiefuzz-wrapper] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2; }

HOST="${HOST:-localhost}"
PORT="${PORT:-9090}"
TARGET="http://$HOST:$PORT"
SPEC_IN="/specifications/$API-openapi.json"

# /tool-output is bind-mounted by RESTgym to results/<api>/<tool>/<run>/tool-output/.
# Fall back to a container-local folder if it is missing or not writable.
OUT=/tool-output
if ! touch "$OUT/.write-test" 2>/dev/null; then
    log "WARNING: $OUT not writable, WuppieFuzz outputs will be lost with the container"
    OUT=/tool/work
fi
rm -f "$OUT/.write-test"
mkdir -p "$OUT"
cd "$OUT" || exit 1

if [ ! -f "$SPEC_IN" ]; then
    log "Specification not found: $SPEC_IN"
    exit 1
fi

# Keep the spec's "servers" consistent with --target.
SPEC="$OUT/$API-openapi.json"
jq --arg url "$TARGET/" '.servers = [{"url": $url}]' "$SPEC_IN" > "$SPEC"

# RESTgym runs `docker stop` TIME_BUDGET minutes after starting this container. Finish 30 s
# earlier so WuppieFuzz exits on its own timeout and flushes report.db (it commits every
# 4096 inserts) and its end-of-run reports.
BUDGET_S=$(( ${TIME_BUDGET:-60} * 60 ))
TIMEOUT_S=$(( BUDGET_S - 30 ))
[ "$TIMEOUT_S" -lt 60 ] && TIMEOUT_S=60

# Forward docker stop (SIGTERM) as SIGINT, which WuppieFuzz handles as a clean shutdown.
CHILD=""
STOPPING=0
trap 'STOPPING=1; [ -n "$CHILD" ] && kill -INT "$CHILD" 2>/dev/null' TERM INT

log "API=$API TARGET=$TARGET TIME_BUDGET=${TIME_BUDGET:-unset} timeout=${TIMEOUT_S}s out=$OUT"

START=$(date +%s)
RESTARTS=0
while [ "$STOPPING" -eq 0 ]; do
    ELAPSED=$(( $(date +%s) - START ))
    REMAINING=$(( TIMEOUT_S - ELAPSED ))
    if [ "$REMAINING" -lt 10 ]; then
        break
    fi
    # Black-box mode: endpoint coverage only. OTLP receivers off, because tool containers use
    # host networking and parallel runs would collide on the default ports 4317/4319.
    # JSON output puts WuppieFuzz's own request counter into <tool>-stdout.log.
    wuppiefuzz fuzz "$SPEC" \
        --target "$TARGET" \
        --timeout "$REMAINING" \
        --report \
        --output-format json \
        --otel-http-receiver-bind off \
        --otel-grpc-receiver-bind off &
    CHILD=$!
    wait "$CHILD"
    CODE=$?
    # `wait` returns early when a trapped signal arrives; wait again for the real exit.
    while kill -0 "$CHILD" 2>/dev/null; do wait "$CHILD"; CODE=$?; done
    CHILD=""

    if [ "$STOPPING" -eq 1 ]; then
        log "stopped by signal (exit code $CODE)"
        break
    fi
    if [ "$CODE" -eq 0 ] && [ $(( $(date +%s) - START )) -ge $(( TIMEOUT_S - 10 )) ]; then
        log "campaign finished on timeout"
        break
    fi
    RESTARTS=$(( RESTARTS + 1 ))
    log "RESTART $RESTARTS: WuppieFuzz exited with code $CODE after $(( $(date +%s) - START ))s; corpus is lost, starting a new campaign in 5s"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) restart=$RESTARTS exit_code=$CODE" >> "$OUT/restarts.log"
    sleep 5
done

log "done: restarts=$RESTARTS"
echo "$RESTARTS" > "$OUT/restart-count.txt"

# RESTgym treats an exited tool container as a failure, so stay alive until it stops us.
while [ "$STOPPING" -eq 0 ]; do sleep 1; done
exit 0
