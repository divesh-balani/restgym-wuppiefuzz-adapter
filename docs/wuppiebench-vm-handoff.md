# WuppieBench PoC: VM handoff for Claude Code

Read this before running anything. It records what was built on the Mac (2026-11-07),
what was wrong with the first results, and what to run on the VM.

## Goal

A black-box proof of concept with all old results discarded and two setups on the same VM:

- **Setup A: upstream RESTgym** (https://github.com/restgym/restgym, unmodified) running **RESTler + EvoMaster**.
- **Setup B: this fork** running **RESTler + EvoMaster + WuppieFuzz**.

APIs scs and market. White-box comes later (see "Out of scope").

How to read A vs B:
- **RESTler is the control.** Its wrapper, the proxy/JaCoCo infrastructure and the API images are identical in
  both repos, so RESTler's A and B results must match (it is near-deterministic). If they don't, the fork
  changed the measurement and the comparison is invalid.
- **EvoMaster shows the effect of the budget fix.** Upstream hard-codes `--maxTime 1h`, so at 15 min it stops at ~25%
  of its search. The fork uses the whole budget. The A vs B difference is expected and is evidence for the fix.
- **WuppieFuzz is new** and is compared against B's RESTler and EvoMaster.

## What exists

- Repo: https://github.com/divesh-balani/restgym-wuppiefuzz-adapter (personal fork of RESTgym, `main`).
  The TNO `WuppieFuzz-benchmark-main` folder was only read, never changed.
- `tools/wuppiefuzz/`: Dockerfile (pinned release + sha256, pinned base digest, non-root), `run.sh`,
  README with caveats. Read `tools/wuppiefuzz/README.md` first.
- `src/run.py` and `src/common.py`: each run gets `results/<api>/<tool>/<run>/tool-output/`, mounted at
  `/tool-output`. `check_enabled()` now skips folders without a config instead of crashing.
- Smoke test on Mac (scs, 5 min): 0 restarts; WuppieFuzz counted 20,839 requests and results.db had 20,800.
  The gap is explained by the proxy's final-batch loss (below).

## Setup on the VM

1. `git clone https://github.com/divesh-balani/restgym-wuppiefuzz-adapter.git restgym && cd restgym`.
2. Submodules use SSH URLs. Use
   `git config --global url."https://github.com/".insteadOf git@github.com:` and then
   `git submodule update --init --recursive`. The pinned evomaster and schemathesis commits fetch fine over HTTPS.
3. Enable only the tools and APIs you need: `tools/{evomaster,schemathesis,wuppiefuzz}/restgym-tool-config.yml`
   and `apis/{scs,market}/restgym-api-config.yml` set to `enabled: true`, with everything else `false`.
4. `./restgym.sh b`. This rebuilds the launcher image, so the `src/` changes take effect.
5. Run a 5-minute dry run of each tool on scs **into a separate results folder** (see issue 5), and check that each one
   sends traffic before starting the real runs.

## Issues to fix or watch (found in the first EvoMaster/RESTler results)

1. **EvoMaster ignored the time budget. FIXED in this fork:** `tools/evomaster` is now vendored (no longer a
   submodule), and `entrypoint.sh` searches for `TIME_BUDGET*60 - 60` s, then idles. Verified on the Mac: 99.6% of budget
   consumed in a 2-minute test. Background: the upstream wrapper hard-codes
   `--maxTime 1h`. In the 15-minute runs, EvoMaster's log ends at "Consumed search budget: 25%", so it was
   killed a quarter of the way through its own search and never reached the budget-dependent phases (e.g. focused
   search at 50%). Its numbers understate it. **Old EvoMaster results are invalid; rerun them.** After each run, check
   that `evomaster-stdout.log` shows ~100% "Consumed search budget" and `[evomaster-wrapper] search finished`.
2. **Proxy final-batch loss (accept and document).** `infrastructure/mitmproxy/store-interactions.py` commits
   every 100 rows, and the last partial batch is lost on stop. Every results.db count is a multiple of 100.
   Measured loss is 2 to 95 rows per run (<0.7%), and it affects all tools equally. A fix (commit in `done()`)
   would need the API images rebuilt, so it's not worth it for the PoC.
3. **Proxy-rejected requests are invisible.** mitmproxy rejects requests with a malformed request line
   ("HTTP protocol error in client request"), and they never reach results.db. RESTler had 2,613 per scs run (~15% of
   its traffic) and 1,170 per market run. EvoMaster had 0. Check this for Schemathesis and WuppieFuzz:
   `grep -c 'HTTP protocol error in client request' logs/<api>-stdout.log`. It doesn't change coverage (the API never
   sees these requests), but it understates request counts, so report it next to them.
4. **"unique 5XX" is inflated by message-text bucketing.** RESTler × market reported 11 buckets, and 9 of them
   are Jackson "JSON parse error: …" variants (one root cause: malformed JSON returns 500). EvoMaster's 2 buckets
   are probably closer to the number of real faults. For the comparison, also report faults grouped by
   exception type and endpoint (manual or scripted), not just `unique_5XX`.
5. **Aggregated CSVs mixed in the 5-minute dry runs. FIXED in this fork:** aggregation keeps only the most common
   time budget (or `RESTGYM_AGGREGATE_BUDGET=<minutes>`) and prints a WARN line for each excluded run. Background: `process_results.py` aggregates *every* run under
   `results/`. The request-budget CSV uses the minimum request count per API across all runs, so the 5-minute
   RESTler dry run set the budget to 5,300/5,400 requests, which truncates every 15-minute run. Keep dry runs out of
   `results/` (move them away) before `./restgym.sh` analysis, and check the `interactions` column in
   `request_budget_*.csv` is the expected minimum.
6. **Market mostly measures a spec/implementation mismatch.** ~70% of market requests never get a 2XX.
   `PUT /customer/cart` takes HAL `_links` bodies that both tools produce wrongly (Jackson "Expected relation name"
   returns 500), and validation errors come back as **406**, not 400. Both tools are stuck at 9 to 10 of 13
   operations and 26 to 29% line / 2 to 3% branch coverage. That's still a valid comparison, but say clearly that market is
   bottlenecked by input format. scs is the cleaner target.
7. **EvoMaster × scs shows 100% 2XX.** That's plausible (schema-valid inputs, and scs only returns 400 for type errors),
   but if Schemathesis/WuppieFuzz also show 0 4XX on scs, check that the proxy records non-2XX at all.
8. **WuppieFuzz specifics** (see its README): status JSON goes to **stderr**
   (`logs/wuppiefuzz-stderr.log`). It quits on its first connection error, so the wrapper waits until the
   proxy stops answering 502. The default crash criteria flag ~79% of sequences, so crashes are packed into
   `crashes.tar.gz`. Check `tool-output/restart-count.txt` is 0 for every run, and exclude or flag runs with restarts.
   The RNG is clock-seeded, so use repetitions.
9. **Docker Desktop on the Mac restarted itself mid-test**, and host networking broke after that. That shouldn't
   happen on a Linux VM, but if a tool sees connection errors, check `curl localhost:<port>` from a `--network host`
   container.
10. **JaCoCo "Invalid execution data file"** appeared once in `scs-stderr.log` (one RESTler run). It looks harmless.
    Check that the coverage curve in that run's `code-coverage/` doesn't drop.

## Experiment protocol (PoC)

- Same VM, same budget (**15 min**), same repetitions (**3**, or 5 if time allows), same parallelism setting in
  both setups. Run A and B one after the other, not at the same time, so they don't compete for CPU.
- Keep the clones separate (`~/restgym-upstream`, `~/restgym-fork`), each with its own `results/`. Dry runs stay
  outside `results/`. Upstream's aggregation does not filter by budget.
- Upstream has no fix for missing config files: initialise **all** its submodules, or its menus crash.
- Record for each setup: repo commit, image digests (`docker images --digests`), VM CPU/RAM, start/end times.

## Accuracy checks per run (script these)

| Check | How | Expected |
|---|---|---|
| Budget respected | `started.txt`/`completed.txt`, coverage samples | ~16 min, ~386 samples |
| Tool used its whole budget | EvoMaster log ~100%; WuppieFuzz "campaign finished on timeout" | yes |
| Proxied vs recorded | flow lines in `<api>-stdout.log` vs `select count(*) from interactions` | gap < 100 |
| Proxy-rejected | `grep -c 'HTTP protocol error'` | report it |
| WuppieFuzz self-report vs proxy | last `.requests` in stderr JSON vs results.db | gap < 100 + rejected |
| Restarts | `tool-output/restart-count.txt` | 0 |
| Coverage monotonic | `code-coverage/*.csv` series | never decreases |

## Deliverable

Three comparisons: (1) RESTler A vs B (control: should match), (2) EvoMaster A vs B (effect of the budget fix),
(3) RESTler vs EvoMaster vs WuppieFuzz within B (the actual tool comparison).

Per API × tool, report median/min/max for: requests (with rejected count), 2XX/4XX/5XX, covered
operations, line/branch/method coverage, time to final coverage, AUC, and 5XX faults by
root cause. Add the WuppieFuzz self-reported vs RESTgym-measured comparison, and a short "threats to
validity" section listing issues 1 to 6.

## Out of scope for the PoC (white-box, later)

In grey-box mode WuppieFuzz resets JaCoCo counters after every execution (`executor.rs:517`), which would corrupt
RESTgym's cumulative sampling on a shared agent. White-box needs a per-run Docker network plus a coverage
multiplexer, or a second agent. EvoMaster white-box needs a driver for each SUT.
