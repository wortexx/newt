# Post-route repair measurement (change `bounded-grt-repair-measurement`) — tasks

Tags:

- **[edit]**: plain file editing, checked locally (`actionlint`, `python3 -m py_compile`, regenerating
  the report from downloaded artifacts, `openspec validate --strict`).
- **[gh]**: read-only `gh`/`az` queries or branch pushes, no VM time.
- **[long-run]**: a P&R lane dispatch on the self-hosted Azure VM (10–16 h, plus ~2.5 h on a
  synth cache miss). Each one is dispatched **only after the user approves it**, never as a
  speculative check. Both before **2026-11-02**, when the reference's checkpoints expire.

## 1. Preconditions (before any edit lands)

- [x] 1.1 **[gh]** Confirm both runs' checkpoints are in Blob storage and note each blob's upload
  date (expiry = upload + 30 days). Verify: `az storage blob list` shows a `basilisk.grt.zip` and a
  `synth-key.txt` under `37108127061/` and `37162759719/`. — done, from the `upload-checkpoints`
  logs instead: the user has no Blob data-plane role, so `az storage blob list` is refused. Both
  runs uploaded 10 checkpoints including `basilisk.grt.zip`, plus `synth-key.txt`: `37108127061`
  at 2026-10-03 23:32 UTC, `37162759719` at 2026-10-04 15:06 UTC. Expiry is therefore
  2026-11-02 23:32 / 2026-11-03 15:06 at the earliest. The dispatch's `restore-checkpoints` job is
  the presence check.
- [x] 1.2 **[gh]** Download both runs' `pnr-reports` artifacts into a scratch dir before their
  30-day artifact retention ends; task 3.3 needs them. Verify: each dir has `save/pnr_status.log`
  and `reports/basilisk.grt.rpt`. — done, in `masterthesis/pnr-artifacts/<run>/` (next to the
  repo, outside git). Both status logs end `grt ok`, `grt stop-after`. Artifact expiry: 2026-11-02
  22:41 and 2026-11-03 13:09 UTC.
- [x] 1.3 **[gh]** Record each run's `Synth cache key inputs` block and `Synth cache key` from
  `gh run view <id> --log` (design D3). Verify: two blocks of 11 lines (10 paths and `yosys`), each
  with its key. — done, saved as `pnr-artifacts/<run>/synth-key-inputs.txt`. `37108127061`:
  `synth-294e5202be38b7a6d042bd09b1b56229` (cache hit then). `37162759719`:
  `synth-de3ba884254699a094cc0c7893f8ad80` (cache miss then, so it synthesized and saved the
  entry). Both: `Yosys 0.69+post (git sha1 143eb14f9...)`.

## 2. Dispatch input (D1)

- [x] 2.1 **[edit]** Add the `skip_grt_repair` input to `pnr.yml` (description: empty = skip,
  `0` = run the bounded repair). Pass it as
  `PNR_SKIP_GRT_REPAIR=${{ github.event.inputs.skip_grt_repair || '1' }}`, and extend the
  existing `PNR_TIMEOUT_GRT_REPAIR / PNR_SKIP_GRT_REPAIR` comment with why the default stays `1`
  and this change's name. Verify: `actionlint .github/workflows/pnr.yml` is clean, and
  `grep PNR_SKIP_GRT_REPAIR=1 .github/workflows/pnr.yml` finds nothing hardcoded.
- [x] 2.2 **[edit]** Document the input next to the other dispatch inputs in `docs/pnr-pipeline.md`
  (what it does, that it is best-effort, the 16 h timeout). Verify: the documented
  `gh workflow run pnr.yml ... -f skip_grt_repair=0` line matches the input's name.
- [ ] 2.3 **[gh]** Land 2.1–2.2 on `main` through a PR (fast lane green). Verify:
  `gh workflow view pnr.yml --yaml` on `main` shows the input.

## 3. Report generator (D5, D6)

- [x] 3.1 **[edit]** `scripts/sha3_ppa.py`: optional `--pnr-repair` / `--pnr-ref-repair` (given
  together, and only together with `--pnr`/`--pnr-ref`). Parse each one's `grt_repair` status
  and, when it is `ok`, the WNS/TNS in `reports/basilisk.grt_repaired.rpt`, plus area from the
  same report. Verify: `python3 -m py_compile scripts/sha3_ppa.py`, and passing only one of the
  pair exits with an error naming both.
- [x] 3.2 **[edit]** Achieved period and labels: take it from `grt_repaired` when both sides'
  repair completed, otherwise from `grt`, labelled "before post-route repair". Add the
  `WNS / TNS after grt_repair` row and an area-after-repair row only when both completed. When repair
  was attempted and did not complete, name the repair run and its outcome. Replace "the latest
  stage the run reached" for a pre-repair figure. Verify: matches the `sha3-evaluation` delta's
  two new scenarios.
- [x] 3.3 **[edit]** Regenerate `docs/results/sha3-ppa.md` from the task 1.2 artifacts without the
  new flags. Verify: `git diff` shows only the repair-status wording, and every number is
  unchanged.

## 4. Measurement branches (D2, D3)

- [ ] 4.1 **[gh]** Cut `measure/grt-repair-ref` at `dff4df0` and `measure/grt-repair-arms` at
  `4c25003`, cherry-pick the 2.1 commit onto each, and push. Verify:
  `git diff --stat <base>..<branch>` touches only `.github/workflows/pnr.yml`.
- [ ] 4.2 **[edit]** On each branch, recompute the key inputs (`git rev-parse HEAD:<path>` for
  each of the 10 paths, plus `yosys -V` from the current `newt-eda:dev`) and compare them with
  task 1.3. Verify: every line matches. If only `yosys` differs, stop and ask the user (D3).
  Pre-checked 2026-10-06, before the branches exist (a `.github/`-only cherry-pick cannot move
  these): all 10 path hashes at `dff4df0` and `4c25003` match runs `37108127061` and
  `37162759719`. The `yosys -V` of `ghcr.io/wortexx/newt-eda:dev` (digest `f5bdfc78…`, last
  published 2026-09-27, before both runs) matches both. Re-run on the pushed branches to tick.

## 5. Reference run (D4)

- [ ] 5.1 **[long-run]** With the user's approval, dispatch on `measure/grt-repair-ref`:
  `resume_from_run=37108127061 resume_exclude=grt_repaired stop_after=grt_repair
  skip_grt_repair=0`. Verify: the log shows "Netlist identity matches", all stages through `grt`
  restored, and `grt_repair` running (not "skipping post-route timing repair").
- [ ] 5.2 **[gh]** Record the outcome: run id, whether synthesis ran (cache miss), `grt_repair`
  status and runtime, and on `ok` the WNS/TNS and area after repair against `grt`. Download its
  `pnr-reports`. Verify: the numbers come from `basilisk.grt_repaired.rpt` and `pnr_status.log`.
  If the stage did not complete, skip group 6 and go to 7.

## 6. Run with both arms (only if 5.2 completed)

- [ ] 6.1 **[long-run]** With the user's approval, dispatch the same inputs on
  `measure/grt-repair-arms` with `resume_from_run=37162759719`. Verify as in 5.1.
- [ ] 6.2 **[gh]** Record the outcome as in 5.2 and download its `pnr-reports`.

## 7. Results and docs

- [ ] 7.1 **[edit]** Regenerate `docs/results/sha3-ppa.md` with the repair artifacts (both, if
  group 6 ran). If both completed, rerun the script's energy tables at the new achieved period.
  Verify: the P&R section states the repair status of every `grt` figure; the achieved period
  names its stage, run and repair status; the energy tables use that period.
- [ ] 7.2 **[edit]** Update `docs/results/sha3-evaluation.md` wherever it quotes 19.23 ns or WNS
  at `grt` with the same stage and repair status. Verify: `git grep -n '19\.23'` either finds
  nothing or finds only figures labelled before repair.
- [ ] 7.3 **[edit]** `docs/infra-plan.md`:
  - Phase 11: the framing question is settled (detailed route not needed, per the
    `sha3-evaluation` stages), and the four routability levers and the larger die move to
    future work;
  - section 0's WNS caveat and Phase 5's "Repair bounding, as built": the measured outcome;
  - Phase 4's stale "not yet archived" note on `ci-synth-lane`.
  Verify: no Phase 11 item is left unticked without a "future work" or "not needed" label.
- [ ] 7.4 **[gh]** Delete both measurement branches once 7.1–7.3 are merged. Verify:
  `git ls-remote --heads origin 'measure/*'` is empty.

## 8. Integration check

- [ ] 8.1 **[edit]** `openspec validate bounded-grt-repair-measurement --strict` passes, and every
  run id quoted in the results and the infra plan matches a run recorded in 5.2 / 6.2.
