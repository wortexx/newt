# Proposal

## Why

The flow ends at `out/basilisk.final.def`. A DEF names its cells but has no geometry inside them, so newt has no layout file: no die image, no GDS to open in KLayout, and nothing a signoff DRC can run on without a hand-built step. The only GDS so far came from the scratch DRC probe (`target/ihp13/openroad/out/drc-probe/stream.py`, not in git). It streamed run `45365266924`'s DEF in 110 s, and its full-die DRC on that GDS found no violations outside the IP waiver list. The repo's own `target/ihp13/klayout/scripts/def2stream.py` is inherited from upstream Basilisk and cannot run: it reads `iguana.final.def` (the flow writes `basilisk.final.def`), looks for the delay line in a `macro_cells/` directory that does not exist, merges an IO GDS the pinned PDK does not have, and lists only three of the six SRAM sizes the floorplan can place.

This is Stage A of `docs/infra-plan.md` Phase 19 (chip finishing, croc-style). Seal ring and minimal DRC (Stage B) and the logo and die render (Stage E) both start from this GDS.

## What Changes

- **A working DEF → GDS step.** `def2stream.py` is rewritten from the probe's validated logic. Its inputs (DEF, LEF list, GDS list, top cell, output) are passed with `-rd`, as in croc's `run_finishing.sh`, instead of hardcoded. It merges each macro GDS with that macro's sub-cells renamed, so they cannot replace the DEF's own via and cell definitions of the same name. It drops the unused library cells the merge brings in, and fails if any instantiated cell other than the IO pads is left without geometry.
- **The IO pads stream empty, on purpose and on record.** The pad ring uses Basilisk's pre-release IO cells (`ixc013_*`, `vddpad`, `corner`, …), which have LEF but no public GDS. Their names are an explicit allow-list, and the step reports how many pad instances are empty. Replacing the pad ring is Phase 19 Stage C, not this change.
- **`make gds`** under `target/ihp13/klayout/`, defaulting to the flow's own `out/basilisk.final.def`, and able to take any other DEF (for example one downloaded from a lane run). Output: `basilisk.gds.gz` and a stream log.
- **KLayout in `newt-eda`**: a pinned release, installed in the final image stage.
- **The P&R lane publishes the GDS.** After the flow, when a DEF exists, the lane streams it and uploads `basilisk.gds.gz` as its own artifact next to the DEF. Streaming is best-effort, like detailed routing: a failed stream is reported in the run summary but does not fail a run whose P&R succeeded.

No PDK, RTL, synthesis or P&R change. No new P&R run is needed: the step is validated on run `45365266924`'s DEF.

## Capabilities

### New Capabilities

- `chip-finishing`: turning the routed design into layout data, starting with the DEF → GDS stream (inputs, sub-cell renaming, empty-cell check, IO allow-list, outputs). Seal ring, DRC and artwork (Phase 19 Stages B and E) will extend it.

### Modified Capabilities

- `eda-tooling-image`: the image's toolchain contents add KLayout at a pinned version.
- `ci-pipeline`: the P&R lane's published outputs add the streamed GDS when a DEF exists, with the same "report, don't fail" rule the DEF already has.

## Impact

- **Flow stages:** a new post-backend stage (GDS stream) and CI (`pnr.yml` gains a stream step and an artifact upload). Tooling image (`docker/all`). No RTL, sim, synth, backend-script or software change.
- **Code:** `target/ihp13/klayout/scripts/def2stream.py` (rewritten), `target/ihp13/klayout/klayout.mk` (new), `target/ihp13/klayout/src/ihp130.lyt` (removed or reduced: inputs move to `-rd`), `iguana.mk` (include + top-level `gds` target), `docker/all/Dockerfile`, `.github/workflows/pnr.yml`, `docs/pnr-pipeline.md`, `docs/infra-plan.md` (Phase 19 Stage A status), `AGENTS.md` (command reference).
- **CI cost:** about 2 minutes and one extra artifact per routed run on the VM. The DEF artifact is 178 MB zipped; the gzipped GDS is expected to be the same order.
- **Image:** grows by KLayout and its Qt/Python runtime dependencies. The `docker-image.yml` workflow rebuilds it on the `docker/**` change.
