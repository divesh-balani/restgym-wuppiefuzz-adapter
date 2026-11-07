# WuppieFuzz for RESTgym

Wrapper for [WuppieFuzz](https://github.com/TNO-S3/WuppieFuzz) (TNO), a coverage-guided REST API fuzzer built on LibAFL.

## How it runs

- The image installs the prebuilt release binary (`WUPPIEFUZZ_VERSION`, default `v1.8.0`) for `x86_64` or `aarch64` Linux. The tarball is checked against the hashes from the release's published `.sha256` files, which are pinned in the `Dockerfile`. The base image `debian:trixie-slim` is pinned by digest. When you bump the version, update the hashes too.
- It runs as the non-root user `fuzzer`, like the upstream image. Specs are not baked in: RESTgym mounts them at `/specifications/` at runtime.
- `run.sh` copies `/specifications/$API-openapi.json`, sets its `servers` to `http://$HOST:$PORT/`, and runs:

  ```
  wuppiefuzz fuzz <spec> --target http://$HOST:$PORT --timeout <budget - 30 s> --report \
    --output-format json --otel-http-receiver-bind off --otel-grpc-receiver-bind off
  ```

- **Timeout**: RESTgym runs `docker stop` exactly `TIME_BUDGET` minutes after starting the tool. WuppieFuzz is given `TIME_BUDGET*60 - 30` seconds so that it ends on its own timeout and flushes `report.db`, which only commits every 4096 inserts. After that the wrapper idles until RESTgym stops it, because RESTgym treats an exited tool container as a failure. A `docker stop` that arrives earlier is forwarded to WuppieFuzz as SIGINT, which it handles as a clean shutdown.
- **Restarts**: if WuppieFuzz exits early with an error (or with exit 0 before the timeout), it is restarted with the remaining time. Each restart is logged to stderr as `RESTART n` and to `tool-output/restarts.log`. The final count is in `tool-output/restart-count.txt`. This count works as a small robustness signal.
- **OTLP receivers off**: tool containers use host networking, so parallel runs would collide on the default ports 4317/4319.

## Outputs kept per run

`run.py` mounts `results/<api>/<tool>/<run>/tool-output/` at `/tool-output`, and WuppieFuzz runs in that folder:

| Path | Content |
|---|---|
| `logs/wuppiefuzz-stderr.log` | WuppieFuzz logs as JSON lines (it logs to stderr; stdout stays empty). Status lines carry a JSON string in `.msg` with `requests`, `executed_sequences`, `endpoint_coverage`, `objectives`. Extract with `jq -r '.msg' logs/wuppiefuzz-stderr.log \| grep '^{"event_msg' \| tail -1 \| jq .requests` |
| `tool-output/reports/grafana/report.db` | WuppieFuzz's SQLite report (requests, responses, coverage, stats). Every restart adds a row to `runs` |
| `tool-output/reports/<timestamp>/` | corpus, mermaid graphs, endpoint-coverage report (one folder per campaign) |
| `tool-output/crashes.tar.gz` | objective inputs (packed after the campaign; see crash criteria below) |
| `tool-output/queue/` | LibAFL corpus queue |
| `tool-output/restart-count.txt`, `restarts.log` | restart accounting |
| `tool-output/<api>-openapi.json` | the spec as it was actually fuzzed |

With these you can compare WuppieFuzz's self-reported numbers with RESTgym's external measurement (proxy `results.db`, JaCoCo) for the same run.

## Caveats for experiments

- **No seed option.** WuppieFuzz seeds its RNG from the clock (`StdRand::with_seed(current_nanos())` in `src/state.rs`), so runs cannot be reproduced exactly. Use repetitions and statistics.
- **Restarts lose the corpus.** A restarted campaign begins again from the initial corpus generated from the spec. Runs with restarts are therefore not comparable with clean runs. Check `restart-count.txt`.
- **Default power schedule: `Fast`** (`BaseSchedule::FAST`). Other schedules (e.g. `--power-schedule coe`) can be added as separate tool folders, such as `tools/wuppiefuzz-coe/`.
- **Default crash criteria flag almost everything.** By default every spec deviation counts as an objective, including undocumented 4xx codes and schema mismatches. On scs, ~79% of executed sequences became objectives in 5 minutes. LibAFL puts objective inputs in `crashes/`, not the corpus, so this probably weakens the feedback loop as well as inflating output. `--crash-criteria Status5xxNotSpecified` (or similar) could go in a separate tool folder. This is a methodological choice, so it is not changed here.
- **Black-box mode only.** WuppieFuzz gets endpoint coverage as feedback, not code coverage. That makes the comparison fair against black-box tools (Schemathesis, RESTler, EvoMaster black-box, …), but it **understates WuppieFuzz**, whose design targets grey-box fuzzing with a JaCoCo/LCOV/OTel coverage agent. RESTgym's API containers attach JaCoCo for measurement, but the tool can only reach `localhost:$PORT` (the proxy), not the agent, so grey-box mode needs infrastructure changes.

Enable it by setting `enabled: true` in `restgym-tool-config.yml`, then build with `./restgym.sh b`.
