# Upgrade yosys to upstream v0.69 (retire the fork)

## Why

The synthesis tool is a custom fork (`phsauter/yosys@3ce5059`): upstream yosys from 2024-04-17 (between 0.40 and 0.41) plus three commits to one file, `passes/techmap/abc.cc`. It is 4,483 commits behind upstream `main` (v0.69, released 2026-09-09), and the two features the fork existed for have diverged in fate: `-liberty_args` landed upstream verbatim (PR #5721, in v0.66+), while the `{tmpdir}` script placeholder never will (PR #4343 closed 2025-09, its successor #4592 closed 2026-07). Phase 8 of `docs/infra-plan.md` (replace `svase`+`sv2v` with the slang frontend) is impossible on the fork: the slang frontend is built into upstream yosys from v0.67 and its standalone plugin only supports 0.52 to 0.66. Two motivations, then: stop carrying stale tooling we cannot patch further, and unblock Phase 8, which needs a modern yosys as its first step.

**Flow stages touched:** synth (one ABC script line pair, the synth-lane metrics parser, the checked-in synth baseline) and CI (the `yosys` image stage, the synth lane's baseline). No RTL, simulation, backend, or software changes. The pickle chain (`morty` → `svase` → `sv2v`) is deliberately **not** touched, so the adoption gate isolates the yosys delta from any later frontend delta.

## What Changes

- Replace the `phsauter/yosys` fork with upstream yosys pinned to the **v0.69** release tag in `docker/yosys/Dockerfile`; build from the release source tarball (which bundles the git submodules upstream now vendors) with the CMake build system upstream moved to, and add the build deps it now needs (`cmake`, `lld`, `libfl-dev`, `gawk`).
- Keep `abc -liberty_args "-S 20 -G 3"` in `yosys_synthesis.tcl` unchanged: upstream has the same option with the same `read_lib` semantics.
- Remove the flow's last dependency on the fork: the `{tmpdir}` BLIF save/reload in `target/ihp13/yosys/scripts/abc-speed-opt-new.script`, resolved per the design's spike (drop it if the ABC `buffer` bug it works around is gone; otherwise substitute a path the flow controls).
- Port `target/ihp13/yosys/scripts/synth_metrics.py` off the text `stat` report (its `Number of cells:` line no longer exists upstream; `stat` prints a table now) onto `stat -json`, which the flow already emits.
- **Adoption gate**: run `make synth-all` on unmodified Basilisk with the new image and diff cell count / area / DFF count against the current `synth-baseline.json` (714,166 cells, seeded 2026-08-29 from the fork), explain the delta, verify the netlist's instance naming still satisfies the P&R lane's SDC and macro scripts, then **reseed `synth-baseline.json`** from the new tool so later coprocessor measurements compare like with like.
- Update the three places that record the fork rule as a standing constraint (`AGENTS.md`, `README.md`, `openspec/config.yaml` context) and the Phase 1 assumptions table plus Phase 8 preamble in `docs/infra-plan.md`.

**BREAKING** in the loose sense: cell count, area and netlist naming will drift, because ABC, `booth`, `peepopt`, `wreduce`, `share`, `opt_merge` and `dfflibmap` all changed between 0.40 and 0.69. This is expected and is exactly what the gate measures; the previous image stays pullable by its immutable tag as the fallback.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `eda-tooling-image`: the "Image toolchain contents" requirement changes from "yosys pinned to the `phsauter/yosys` fork at `3ce5059`" to "upstream yosys at the v0.69 release, with the built-in slang frontend available"; the "runs the existing synthesis flow at parity" requirement gains the tool-bump adoption gate against the checked-in `synth-baseline.json` (not the 2024 `.rpt`), a netlist-naming compatibility check for the backend scripts, and the baseline-reseed obligation; the fallback scenario points at the previous immutable `newt-eda` tag rather than the 2024 `pulp-iguana` image.

## Impact

- `docker/yosys/Dockerfile`, `docker/yosys/packages.txt`: new source, new build system, new deps. `docker-image.yml` needs no change (it already rebuilds on `docker/**`), but note that merging to `main` moves `:dev`, and `synth.yml` runs on `:dev`, so the synth lane switches to the new yosys on the same merge.
- `target/ihp13/yosys/scripts/abc-speed-opt-new.script`: the `{tmpdir}` lines. `yosys_synthesis.tcl` and `yosys_common.tcl` are expected to need no edits (verified against upstream's current pass options: nothing the flow uses was removed).
- `target/ihp13/yosys/scripts/synth_metrics.py`, `.github/workflows/synth.yml`: parser switches to the JSON stat report; the workflow passes the JSON path instead of the `.rpt`.
- `target/ihp13/yosys/synth-baseline.json`: reseeded after the gate. Until then the synth lane's drift summary reports the cross-tool delta, which is informational only (the lane does not fail on drift, per the `ci-pipeline` spec).
- Downstream risk: netlist naming drift can silently break patterns in `target/ihp13/src/basilisk_instances.sdc` and `target/ihp13/openroad/scripts/macros*.tcl`. The gate checks this by grep; fixing a broken pattern is in scope only if it is a rename, not a flow change.
- Thesis timing: this must land **before** Phase 7 coprocessor PPA measurements begin, so no baseline has to be re-measured mid-thesis.
- Out of scope: the Phase 8 frontend swap itself (its own change, sequenced after this one so its gate compares against the reseeded baseline); any `yosys_synthesis.tcl` tuning to exploit new passes.
