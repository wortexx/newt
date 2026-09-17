# Upgrade yosys to upstream v0.69 — design

## Context

See proposal.md — Why. What the fork actually is: upstream commit `171577f90` (2024-04-17) plus a 52-line change to `passes/techmap/abc.cc` adding `-liberty_args` and `{D}`/`{tmpdir}` placeholder substitution inside user ABC scripts. Where the flow touches those features today:

- `-liberty_args "-S 20 -G 3"` — `yosys_synthesis.tcl`, combinational path (the default; `YOSYS_USE_ABC_SEQ=0`). Upstream v0.66+ has the option under the same name (PR #5721).
- `{D}` — pre-substituted by `processAbcScript` in `yosys_common.tcl` before yosys ever reads the script; does not rely on the fork.
- `{tmpdir}` — `abc-speed-opt-new.script` lines 71–73: `write_blif "{tmpdir}/tmp.blif"; read_lib -w "{TECH_CELLS}"; read_blif "{tmpdir}/tmp.blif"`, a save/reload around an ABC `buffer` bug. This is the only fork-only feature the flow uses.

Upstream build changes since the fork base: CMake ≥ 3.28 replaces the Makefile entrypoint, C++20 required, abc/slang/fmt/cxxopts/etc. are git submodules (a GitHub `archive/<sha>.tar.gz` no longer contains a buildable tree), and the slang frontend is compiled in from v0.67. Upstream `stat` no longer prints `Number of cells:`, which `synth_metrics.py` greps; it still prints `Chip area for [top ]module` and `=== design hierarchy ===`, and `stat -json` carries `num_cells`, `area` and `num_cells_by_type` per module.

Upstream's `abc` pass now runs per-module ABC invocations on worker threads (external-process mode; capped by `YOSYS_MAX_THREADS`) with a pooled set of long-lived ABC processes. With `YOSYS_FLATTEN_HIER=1` the design still has ~25 kept-hierarchy islands (`YOSYS_KEEP_HIER_INST`), so several ABC runs execute concurrently from the same cwd. That both promises a shorter synth wall time (ABC was the 1–2-thread bottleneck in infra-plan Appendix A) and makes any shared fixed-path temp file a race.

Constraints: the pickle chain stays untouched so the gate measures yosys alone; the previous image must remain reachable; the synth lane runs on the moving `:dev` tag, so merging the Dockerfile flips the lane's tool on the same merge.

## Goals / Non-Goals

**Goals:**

- Zero patches on top of upstream yosys if the spike allows it; if not, a patch *file* in `docker/yosys/` applied at build time, never a fork repository.
- The adoption gate reuses the synth lane and its metrics script rather than a hand-run comparison, so the numbers are produced by the same code path that will report drift afterwards.
- Preserve ABC parallelism (do not pin `YOSYS_MAX_THREADS=1` as a permanent workaround).

**Non-Goals:**

- Any change to `yosys_synthesis.tcl`'s pass sequence to exploit newer passes (`abc_new`, `opt_merge` parallelism tuning, `-relativeshare`, …). Same script, new tool.
- Replacing `svase`/`sv2v` with `read_slang` (Phase 8, next change).
- Fixing the pre-existing `*ddr_rcv_clk_o*` SDC pattern mismatch that leaves WNS "unavailable" in the synth lane, unless the naming check shows it is a rename this tool bump introduced or cures.
- Re-running the P&R lane as part of this gate (a detail-routed result is not a gate anywhere in this project).

## Decisions

**D1 — Build upstream v0.69 from the release source tarball with CMake.**
`docker/yosys/Dockerfile` switches `YOSYS_REPO`/`YOSYS_COMMIT` to `YOSYS_VERSION=v0.69` and fetches `https://github.com/YosysHQ/yosys/releases/download/v0.69/yosys.tar.gz`, which ships the submodules inline, then `cmake -B build -DCMAKE_INSTALL_PREFIX=/build` with clang, `cmake --build build -j$(nproc)`, `cmake --install build`. `packages.txt` adds `cmake`, `lld`, `libfl-dev`, `gawk` (upstream's documented list); Ubuntu 24.04's `cmake` 3.28.3 meets the ≥ 3.28 floor. Alternatives: `git clone --recursive` at the tag (works, but downloads several submodule histories and needs `git` in the builder — the tarball is smaller and matches the existing "curl a tarball" pattern); building from `main` (unpinned, rejected for reproducibility — every other tool in the image is an exact pin).

**D2 — `-liberty_args` stays; no script change for it.**
Upstream's option has the same name, quoting rule and `read_lib` placement as the fork's. Verified against upstream `abc.cc` and its help text. A build-time assertion (`yosys -p 'help abc' | grep liberty_args`) in the smoke test guards against a future upstream rename.

**D3 — Resolve `{tmpdir}` by spike, with a fixed preference order.**
The save/reload exists to dodge an ABC `buffer` bug (comment in the script: "currently there is a bug in buffer making this necessary"). Order of resolution:

1. **Spike**: run the combinational ABC script without the three save/reload lines on one kept-hierarchy module (e.g. `i_uart` or `i_gpio`) in v0.69, and again with them, and compare `stime` and `print_stats` output. If `buffer -p` behaves identically or the round-trip changes nothing measurable, delete the lines. Expected outcome: v0.69's bundled ABC is 2+ years newer than the fork's.
2. If the bug persists: carry the fork's `{tmpdir}` substitution as `docker/yosys/tmpdir-placeholder.patch`, applied by `patch -p1` in the Dockerfile before configuring. Open a standalone upstream PR for the same placeholder (the maintainer explicitly invited piecewise submissions when closing #4592) so the patch can be dropped at the next bump.

   **Cost revised upward during implementation — this is not a ~10-line patch.** Comparing the fork's `abc.cc` against v0.69's directly: upstream, a file-based `-script` is never read by yosys at all. It emits `source <the user's own path>` into the ABC script and lets ABC read the file in place, which is also why upstream substitutes `{D}` only in its *built-in* scripts. The fork changed that shape: it reads the script file into a `user_script` string, substitutes placeholders over it, writes the result into the temp dir as `user.script`, and sources *that*. Porting `{tmpdir}` therefore means reintroducing the read, the string, the substitution and the extra temp-file write — inside v0.69's threaded per-run/global tempdir split, not the fork's single `tempdir_name`. Budget a day, not an hour, and prefer option 1 or 3.

3. Fallback if the bug persists and the patch is not worth its cost: substitute a fixed scratch path from `processAbcScript` (the same mechanism that already resolves `{REC_AIG}` and `{TECH_CELLS}`) **and** set `YOSYS_MAX_THREADS=1` in `yosys.mk` to serialize ABC.

   The serialization is genuinely required, confirmed against v0.69's source: it launches ABC as `"<exe>" -s -f <script>` with **no `cd` into the per-run temp dir** (it passes absolute paths for `input.blif`/`output.blif` instead), and it pools and reuses ABC processes. So every concurrent run shares one cwd, and any fixed relative or absolute scratch filename races.

   **This is cheaper than it first appears.** ABC in this flow was already effectively single-threaded (infra-plan Appendix A: "mostly 1-2 threads (ABC)"), so capping threads forfeits a *potential new* speedup from v0.69's parallel ABC rather than regressing anything that exists today. Weigh it against option 2 on that basis, not as a last resort.

Alternative rejected: a per-module path from Tcl. Impossible — the user script is one shared file `source`d by every module's ABC run, so Tcl cannot vary it per invocation.

**D4 — `synth_metrics.py` reads `stat -json`, not the text table.**
`yosys_synthesis.tcl` gains one line next to the existing area report: `tee -q -o "${report_dir}/${proj_name}_area.json" stat -json -top $top_design {*}$liberty_args`. The parser takes the JSON's top-module entry (`num_cells` with the "including submodules" value, `area`, and the `num_cells_by_type` map filtered on the `sg13g2_df` prefix for DFFs), so the hierarchical double-count the text parser had to special-case disappears. `synth.yml` passes the `.json` path; the `.rpt` remains written for humans. The `check` report parsing (`Found and reported N problems`) is unchanged — that string still exists upstream. Alternative: regex the new text table — brittle, and JSON was already the flow's own machine-readable format elsewhere.

**D5 — Adoption gate runs as an ordinary synth-lane dispatch on the PR build's image, before merge.**
`docker-image.yml` only publishes on `main`, but PR runs already push per-stage `:ci` images and assemble a `newt-eda:smoke-test` composite. The gate needs the composite pullable, so the PR run additionally pushes the composite as `ghcr.io/wortexx/newt-eda:pr-<number>` (immutable, one per PR head); `synth.yml` gets a `workflow_dispatch` input `image_tag` (default `dev`) so the gate is `synth.yml` dispatched with `image_tag=pr-<n>` on the self-hosted runner. The run's metrics summary (D4 parser, old baseline) is the gate record. Alternative: manual `make synth-all` on a dev box as in Phase 1 — works, but the lane exists precisely so this is not a manual overnight anymore, and it exercises the parser change at the same time.

**D6 — Netlist-naming check is a grep over the gate netlist, in the same dispatch.**
After `synth-all`, a small script greps `out/basilisk.yosys.v` for each pattern the backend uses: `*RM_IHP*`, `*i_delay_line*`, the `$HYPERBUS...i_delay_line` and `i_ddrmux.i_mux` hierarchical paths, every `get_cells`/`get_nets` glob in `basilisk_instances.sdc`, and the `_reg` suffix on DFF instances. Any pattern with zero matches fails the step with the pattern named. The `*ddr_rcv_clk_o*` pattern is expected to fail both before and after (pre-existing); it is reported, not gating, and its status is recorded either way. Alternative: run the P&R lane's floorplan stage — too heavy for a gate that a grep answers.

**D7 — Reseed the baseline from the gate run, in the same PR, after the gate passes.**
`synth-baseline.json` is rewritten with the gate's cells / area / DFFs, `wns_ps` carried over as "unavailable" if STA still does not populate, `source` naming this change, `date`, `image` = the `pr-<n>` tag at gate time (updated to the published `<date>-<sha>` tag in a follow-up commit once `main` publishes), and a new `yosys` field = `v0.69`. The previous baseline block is kept in `docs/infra-plan.md` for the record. Consequence: the first `main` synth-lane run after merge should report ~zero drift; if it does not, the moving-tag switch (Context) is the first suspect.

**D8 — Documentation of the fork rule is retired, not softened.**
`AGENTS.md`, `README.md` and `openspec/config.yaml` currently say "custom fork, do not rebase". After this change the rule is "upstream, pinned by release tag in the Dockerfile; bump via a change with the adoption gate". `README.md`'s PR-4343 sentence goes. `docs/infra-plan.md`: Phase 1 assumptions table row updated, Phase 8 preamble gains "requires yosys ≥ 0.67 — done by `upgrade-yosys-upstream`", and the `synth_metrics.py`/baseline notes in Phase 4 point at the JSON report.

## Risks / Trade-offs

- [QoR delta is large or in the wrong direction] → The gate explains before adopting; the tool's release notes (ABC, `booth`, `peepopt`, `dfflibmap` enable inference) are the expected explanations. Only if the delta is unexplained *and* worse do we hold; the previous image tag stays the synth lane's fallback (spec fallback scenario).
- [v0.69 tarball or CMake build fails on ubuntu:24.04 with clang] → Fall back to gcc-13 (upstream CI builds both); as a last resort use `git clone --recursive` at the tag. Detected on the PR's image build, cheap.
- [`{tmpdir}` spike is inconclusive because the original `buffer` bug is undocumented] → Treat "no measurable difference with and without the round-trip on two modules" as sufficient to delete; the full gate then confirms on the whole design. D3 step 2 is the safety net.
- [Parallel ABC plus pooled ABC processes changes results run-to-run] → Upstream states determinism is preserved for the multi-threaded path; verify by running the gate twice only if the first run's numbers look suspicious. Not a gate step by default (2.5 h each).
- [Netlist naming drift breaks an SDC pattern the grep does not cover] → The grep covers every literal pattern in the three backend files; hierarchical-path variables built from `$CHS_*` prefixes are expanded by hand into the grep list once. Anything beyond that surfaces at the next P&R lane run, which is not gated by this change.
- [Merging flips `:dev` and the synth lane's tool before the baseline commit lands] → D7 puts the reseed in the same PR, so the flip and the baseline move together.
- [Synth wall time changes] → Likely shorter (parallel ABC). If it grows past the lane's timeout, cap `YOSYS_MAX_THREADS` to the runner's core count minus headroom rather than reverting.
- [Upstream renames `read_slang` or removes the built-in frontend before Phase 8 starts] → Pinned tag; the smoke test asserts the command exists, so a later bump cannot silently lose it.

### D9 — `abc -liberty_args` crashes v0.69 in this flow's exact configuration (OPEN, blocks the gate)

The flow passes `-liberty_args "-S 20 -G 3"` on its default combinational path together with a user `-script` file. On v0.69 that combination kills ABC. **Confirmed on native x86_64**, not an emulation artifact (CI probe run 35252940096, `ubuntu-latest`, image `newt-eda:pr-32`):

| case | user `-script` | `-liberty_args` | native x86_64 | emulated arm64 |
| --- | --- | --- | --- | --- |
| A | yes | yes | **CRASHED** | **CRASHED** |
| B | yes | no | completes (buffering, resizing, final timing) | completes |
| C | no (default) | yes | no crash | no crash |

Case A is the flow's real configuration, so this blocks the adoption gate and any real `synth-all`.

**Mechanism.** yosys reports `ERROR: ABC failed with status 8B`; `0x8B` is `128 + 11`, so ABC was killed by SIGSEGV (the emulated run says so directly: `qemu: uncaught target signal 11`). The crash tracks the `-liberty_args` flag itself, not the surrounding machinery:

| configuration | result |
| --- | --- |
| `-liberty_args`, pooled ABC (default) | segfault |
| `-liberty_args`, `-exe <copy>` (forces one-shot ABC) | **still segfaults** |
| no `-liberty_args` | works: 2207 gates, 22074 area, 4143.90 ps |

`read_lib -S 20 -G 3 -w <lib>` on its own in a one-shot ABC is fine and reports "slew 20.00 ps and gain 3.00", so the arguments parse correctly. The `-exe` run also printed timing (4109 gates, 33989 area) *before* dying, which shows `-S 20 -G 3` really does derive a different and much larger genlib; the crash comes later, in the script's mapping/buffer/resize sequence over that library.

**Two superseded hypotheses, recorded so they are not re-derived:**
- *printf UB*: the three `std::string` values passed to `%s` in the `read_lib` `stringf` call look like classic UB, but v0.69's `stringf` is a type-safe variadic template (`kernel/io.h`). Not the defect.
- *pooled-ABC path*: v0.69 reuses a long-lived ABC process, gated on `is_yosys_abc()`. Passing `-exe` with a different path does skip that branch, and the crash persists anyway. Not the defect.

Options:

1. **Drop `-liberty_args` from `yosys_synthesis.tcl`.** The only configuration that works on v0.69, verified natively and emulated. yosys then takes the newer merged-SCL path (`read_scl`) instead of the legacy `read_lib` one. This is the recommended fix.
2. ~~Disable the pooled-ABC path via `-exe`~~ — tested, does not avoid the crash.
3. Report upstream and carry a patch, or pin a different release. Only if option 1 proves unacceptable on QoR.

**Applied.** Option 1 is implemented in `yosys_synthesis.tcl`'s combinational path, with the rationale recorded inline at the call site. Verified end to end on v0.69: yosys exits 0, and ABC's buffering, resizing and final timing all run. A synthetic-DUT run reports 32 `check` problems (undriven output bits), but the fork-era image reports exactly the same 32 with the identical harness, so they are an artifact of the reduced test pipeline rather than anything this change introduces. The real flow's `check` is what the gate reads.

**On measuring the QoR cost.** `-S 20 -G 3` exists to give ABC a real delay model, so dropping it plausibly changes results. Repeated attempts to measure this on a small synthetic DUT against the fork-era image were not productive: the baseline arm kept failing for harness reasons rather than real ones. The right instrument already exists — the adoption gate (task 5.1) runs the full design and diffs cell count, area and DFF count against the checked-in `synth-baseline.json`. That is a far better measurement than a toy module, and it is a step this change has to take anyway. Take option 1, then let the gate quantify the delta and explain it, exactly as the gate's own scenario requires.

Whichever is chosen, the gate cannot run until it is.

## Migration Plan

1. Branch: Dockerfile + `packages.txt` (D1), smoke-test assertions (D2), `synth_metrics.py` + `yosys_synthesis.tcl` JSON report + `synth.yml` path and `image_tag` input (D4, D5), naming-check script (D6). PR run builds the image and pushes `pr-<n>`.
2. `{tmpdir}` spike (D3) inside the `pr-<n>` image on a small module; apply the outcome (delete lines, or add the patch file) and push.
3. Dispatch `synth.yml` with `image_tag=pr-<n>`: adoption gate + naming check. Record numbers and explanation in the PR and in `tasks.md`.
4. Reseed `synth-baseline.json` (D7) and update docs (D8) on the same branch. Merge.
5. Post-merge: `main` publishes `<date>-<sha>` and moves `:dev`; the next synth-lane run confirms ~zero drift; follow-up commit records the published tag in the baseline `image` field.
6. Rollback at any point: revert the PR, or point `synth.yml`'s container at the previous immutable tag (`2026-08-29-8d13fe0` or whatever `:dev` last resolved to).

## Open Questions

- Whether the `pr-<n>` composite tag should be garbage-collected after merge. Harmless if left; a GHCR retention rule can be added later without affecting this change.
- Whether to keep `_area.rpt` at all once the JSON is the parsed artifact. Kept for now (humans read it); can be dropped in a later cleanup.
