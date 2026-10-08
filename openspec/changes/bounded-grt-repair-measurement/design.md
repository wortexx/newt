## Context

See proposal.md for why. The facts that shape the approach:

- **Repair is off by a hardcoded value.** The `Place and route` step in `.github/workflows/pnr.yml`
  passes `PNR_SKIP_GRT_REPAIR=1` and `PNR_TIMEOUT_GRT_REPAIR=57600` on every run.
  `grt_repair.tcl` with the skip off runs `repair_design`, an incremental route, `repair_timing`
  (power recovery, then setup and hold, bounded at `-repair_tns 20 -max_buffer_percent 15`), a full
  `global_route`, a hold repair and another incremental route. Each route uses the same 14
  iterations with `-allow_congestion` as `grt.tcl`. It saves `grt_repaired_initial`,
  `grt_repaired_timing` and `grt_repaired` checkpoints and `report_metrics` files under the same
  names.
- **Resume works by restoring checkpoints, guarded by netlist identity.** The workflow computes a
  synth cache key from the tree hashes of `Bender.{yml,lock}`, `hw`, `target/ihp13/{yosys,pickle,pdk,src}`,
  `Makefile`, `iguana.mk`, `tools.mk` and the `yosys -V` string. It restores the VM-local synth
  cache for that key, or runs `synth-all` on a miss. Only then does it compare the key with the
  `synth-key.txt` stored next to the checkpoints, and it refuses on a mismatch. `.github/` and
  `target/ihp13/openroad/` are not key inputs.
- **The two runs come from different trees.** Reference `37108127061` ran `dff4df0` (branch
  `raise-gpl-density-target`). The run with both arms, `37162759719`, ran `4c25003`. `main` has
  since changed `hw/coproc/tb/*` and `target/ihp13/yosys/*`, so its key matches neither.
- **The results page is generated.** `scripts/sha3_ppa.py` reads two `pnr-reports` artifacts
  (`--pnr`, `--pnr-ref`). It parses `basilisk.{dpl,cts,grt}.rpt` and `save/pnr_status.log`, and
  derives the achieved period from the latest gated stage. A resume run's artifact holds only the
  reports that run produced. Restored stages are logged as skipped, so the generator needs both
  artifacts for each side.
- **The cost history.** `pnr-bringup-6` hit the 16 h ceiling in this stage when `grt` itself took
  ~9 h at 101 % demand. Now `grt` takes ~3 h 10 m.

## Goals / Non-Goals

**Goals:**

- Measure the bounded post-route repair as written, once, on both sides of the comparison, from
  their existing `grt` checkpoints.
- Make the repair status of every global-route timing figure explicit in the generated report.

**Non-Goals:**

- Tuning repair (`-repair_tns`, buffer limits, power recovery) or the stage timeout. One shot at
  the written bounds. A timeout is a result, not a prompt to iterate.
- Turning repair on for scheduled runs. The default stays skipped.
- Running `drt`, or using any of Phase 11's routability levers.
- Fixing Phase 17 (default-activity power). Power after repair is not quoted.

## Decisions

### D1. A dispatch input on `main`, cherry-picked onto measurement branches

`skip_grt_repair` is a `workflow_dispatch` input, empty by default. The `run:` line uses
`PNR_SKIP_GRT_REPAIR=${{ github.event.inputs.skip_grt_repair || '1' }}`, the same pattern as
`gpl_density`/`die_scale` but with an explicit `'1'` fallback, so an empty input keeps today's
behaviour. The change lands on `main` through a normal PR. The same commit is then cherry-picked
onto two measurement branches.

*Alternatives.* Setting the env value to `0` only on the measurement branches would leave `main`
with no way to run repair on demand. It would also make each branch's workflow differ from `main`
in a way that no PR ever reviewed. Adding the input only on the branches would work for the
dispatch, because GitHub reads the dispatched ref's workflow file. It would still leave the
capability unmerged and the `ci-pipeline` spec describing inputs `main` lacks.

### D2. One measurement branch per run, cut at the run's own source commit

`measure/grt-repair-ref` is cut at `dff4df0` and `measure/grt-repair-arms` at `4c25003`. Each gets
only the D1 commit. That commit touches `.github/workflows/pnr.yml`, which is not a key input, so
each branch reproduces its original run's synth key. Dispatching from `main`, or from either
original branch merged forward, would change `hw/` or `target/ihp13/yosys`, and the guard would
refuse.

The branches are not merged. They are deleted once the results are recorded and the change is
archived. The run ids, not the branches, are the durable reference.

### D3. Prove the key before paying for a dispatch

The guard runs after synthesis. A key mismatch on a cache miss would therefore first cost a ~2.5 h
`synth-all` and then refuse. Before each dispatch:

1. Read the original run's `Synth cache key inputs` block from its log
   (`gh run view <id> --log`).
2. Compute the same lines on the measurement branch (`git rev-parse HEAD:<path>` for each path, plus
   `yosys -V` from the current `ghcr.io/wortexx/newt-eda:dev`).
3. Dispatch only when every line matches.

If only the `yosys` line differs, the image was rebuilt since the run. Stop and ask the user. The
only ways around it are pinning the old image digest on the branch or a full re-run, and both
change the cost.

A matching key can still miss the VM-local cache, which keeps the newest 5 entries. Then the run
re-synthesizes (~2.5 h, ≈ $3) before resuming. That costs time but is correct: resumed stages load
the physical database from the checkpoint, and the key matches. It is noted in the run's record,
not worked around.

### D4. Reference first; the second run depends on the first

Both dispatches use `resume_from_run=<original id> resume_exclude=grt_repaired
stop_after=grt_repair skip_grt_repair=0`, with the other inputs empty. Neither original run
produced `grt_repaired` (both stopped after `grt`), so the exclusion is a no-op kept for safety. The
lane's concurrency group serializes the two dispatches anyway.

- If the reference's `grt_repair` completes (`grt_repair ok`), dispatch the run with both arms.
- If it times out or fails, do not dispatch the second run. The spec requires both sides to share
  a repair status, so a second run could not change what is quoted. Record the outcome and go to
  the reword path (D6).
- If the reference completes and the second run then fails, quote both without repair, and record
  both outcomes.

### D5. Reports from two artifacts per side

`sha3_ppa.py` gains `--pnr-repair` and `--pnr-ref-repair`: each repair run's `pnr-reports` dir,
optional. Each can be given alone, because under D4 the second side is not
dispatched once the first did not complete. (The first draft required them together; changed
2026-10-07, when the reference's repair timed out.) From each it reads `save/pnr_status.log` for the
`grt_repair` outcome and `reports/basilisk.grt_repaired.rpt` for WNS/TNS. The P&R table gains a
`WNS / TNS after grt_repair` row when both completed.

The achieved period then comes from the `grt_repaired` WNS of the run with both arms. Otherwise it
comes from `grt` as today, and the source text says "after `grt`, before post-route repair". The
stage text no longer reads "the latest stage the run reached" for a figure taken before repair.
Requoting the energy tables needs no new logic: they already take the achieved period as an
input.

*Alternative.* Merging the two artifacts into one directory by hand before running the script. It is
less code, but the provenance (which run produced which figure) is then lost from the report.

### D6. What counts as completed, and the reword path

The repair is quoted when `grt_repair` logs `ok` within its 16 h timeout and
`basilisk.grt_repaired.rpt` exists. The WNS after repair is quoted as measured, even if repair only
partly closes the gap. "Completed" refers to the stage finishing, not to timing closing. Area and
buffer growth from the repair are reported next to the WNS, because `-max_buffer_percent 15` can
add real area.

If either side did not complete, the report keeps the `grt` figures. It labels them and the
achieved period as "before post-route repair", and it names the repair attempt's run and outcome
(timeout or failure). The infra plan records the same outcome, so `grt_repair` is not re-tried
without a new reason.

## Risks / Trade-offs

- [The stage times out again at 16 h] → It is a result (D4, D6). One timeout costs ~16 h ≈ $20,
  and the second run is not dispatched.
- [The image was rebuilt and `yosys -V` changed] → D3 catches it before any VM time is spent, and
  the user decides.
- [The synth cache entry was pruned] → ~2.5 h of re-synthesis per run. It is accepted and recorded
  (D3).
- [Checkpoints expire, 30 days after upload, ~2026-11-02/03] → Both dispatches are scheduled well
  before that. If they are missed, a full re-run (~15 h before `grt_repair`) is the fallback,
  still only with user approval.
- [Repair improves WNS but adds noticeable area] → Both are reported. The SHA-3 blocks' own area
  comes from synthesis per instance, so the block results are unaffected.
- [The two sides' repair converges to different degrees by chance] → One run each, as for every
  other P&R figure here. The report's existing "one run each" caveat covers it, and the
  coprocessor delta is quoted with that caveat.

## Migration Plan

The workflow default keeps `PNR_SKIP_GRT_REPAIR=1`, so merging changes no scheduled or tag run.
Rollback is reverting the one workflow commit. The measurement branches are deleted after the
results are recorded.
