# Design

## Context

See proposal.md (Why) for the motivation and the defects in the inherited `def2stream.py`.

What exists to build on:

- **The probe** (`target/ihp13/openroad/out/drc-probe/stream.py`, git-ignored scratch). It reads the DEF with a LEF list, clears every non-`VIA_` cell the DEF reader created, then merges each GDS through a temporary layout in which every non-top cell gets a `G<k>_` prefix. It logs empty cells, deletes extra top cells, and writes the GDS. On run `45365266924`'s 1.74 GB DEF it took 110 s (DEF read 64 s). Its output is 1.95 GB uncompressed. It found 48 empty cells: the 12 IO cells, plus 36 `G<k>_RM_IHPSG13_1P_BITKIT_*` sub-cells that the SRAM GDS files ship empty. It found 25 extra top cells, all unused standard cells. The full-die DRC on that GDS gave the signoff result recorded in `docs/infra-plan.md` (run 2, 2026-11-24/25).
- **The P&R side.** `init_tech.tcl` reads the LEFs: tech, stdcell, `future/sg13g2_iocell`, six SRAM sizes, and the delay line's `.abst.lef`. The stream must use the same LEFs, because KLayout resolves the DEF's cell outlines and pins against them. `final.tcl` writes `out/${proj_name}.final.def` from cwd `target/ihp13/openroad`. `pnr.yml` uploads it as `basilisk-pnr-def` when it exists.
- **Croc's version** (`klayout/run_finishing.sh --gds`) passes `in_def`, `lef_files`, `gds_files`, `layer_map`, `design_name` and `out_file` as `-rd` variables to its `def2stream.py` and writes `<proj>.gds.gz`.
- **The image.** `docker/all/Dockerfile` is the final `ubuntu:24.04` stage. It already installs Qt5 widget/SVG libs and `libgl1` (for the OpenROAD GUI) and pulls Verible as a release tarball with no builder stage.

## Goals / Non-Goals

**Goals:**

- A GDS that is the probe's GDS plus top-level pin labels, produced by committed, parameterized code, so the DRC evidence and the die images come from the flow, not from scratch.
- One code path for local runs (any DEF) and the lane.

**Non-Goals:**

- Seal ring, DRC in the flow, fill, logo (Phase 19 Stages B, D, E). The script's structure must leave room for them, but none of them is built here.
- The IO pad ring's geometry (Stage C).
- Moving the PDK pin, or using a newer PDK's GDS for anything.
- Retiring `chip.tcl`'s legacy monolithic flow or its `iguana.final.def` naming.

## Decisions

### D1. Rewrite `def2stream.py` around the probe's merge, inputs via `-rd`

The script takes `in_def`, `lef_files`, `gds_files`, `design_name`, `out_file`, `layer_map` and `io_allow` (a regex) as KLayout `-rd` variables, croc's interface. The Makefile, not the script, holds the paths. Steps, in order:

1. Read the DEF with the given LEFs and layer map (`read_lef_with_def = False`, dbu 0.001).
2. Clear every cell except the top and the `VIA_*` cells generated from the DEF/LEF vias.
3. For each GDS, `k = 0..n`: load it into its own layout, rename every cell that is not a top cell of that file to `G<k>_<name>`, then merge it into the main layout. Top cells keep their names, so they bind to the DEF's instances.
4. **Empty check, scoped to what the DEF instantiates.** Collect the cells the top cell instantiates directly. Every empty one fails the run unless it matches `io_allow`. Empty cells deeper in the hierarchy (macro sub-cells) are logged as a count only.
5. Delete every top cell other than `design_name`, recursively.
6. Add the top-level pin labels (D3) and write `out_file`. A `.gz` suffix makes KLayout compress the output.

Exit status is the number of errors (0 = success), and each step logs its timing, as the probe does.

The merge goes through a temporary GDS file per macro, as in the probe. An in-memory `copy_tree` between layouts would avoid the file, but the probe's route is the one the DRC result was measured on. Changing it is not worth re-measuring a 7 h sweep.

**Alternatives.**
- *Upstream ORFS `def2stream.py` as is (the current file):* no renaming, so the probe's renaming finding (macro vias and bit-cells replacing the DEF's own) comes back. It also treats every empty cell, including the SRAMs' shipped empty sub-cells, as an error.
- *OpenROAD-native GDS output:* OpenROAD has no GDS writer that merges library GDS. KLayout is the standard tool here (ORFS, croc).
- *Magic:* no advantage, and a second layout tool to pin.

### D2. Inputs are the P&R LEFs, plus the GDS of every placeable macro

The LEF list mirrors `init_tech.tcl` exactly, including the delay line's `.abst.lef`, not the `.lef` the old `ihp130.lyt` used. The GDS list is the stdcell GDS, the delay-line GDS (`target/ihp13/src/mc_delay/`) and all six SRAM GDS sizes in the PDK. A size the DEF does not use costs about a second to merge, and its cells are dropped in step 5, so the list does not need to track the floorplan. `klayout.mk` defines both lists once.

`ihp130.lyt` is deleted. Its LEF list is stale, and the layer map moves to an explicit map file, `target/ihp13/klayout/src/sg13g2.map`: the probe's mapping plus pin and text purposes. One place for each input. Nothing else in the repo references the `.lyt`.

### D3. Layers: drawing layers as in the probe, pins also on drawing, names as text

Routing and vias go on the drawing datatypes the probe used (Metal1 8/0 … TopMetal2 134/0, Via1 19/0 … TopVia2 133/0). DEF pin shapes go on the metal's drawing layer too, as in the probe: a pin is metal. On top of that, each top-level pin's name is written as a text on that metal's text datatype, read from the PDK's `libs.tech/klayout/tech/sg13g2.lyp` (`<Metal>.text`). Croc's map does the same. Labels cost nothing in DRC and are what LVS (later) and anyone reading the GDS need.

The probe disabled obstructions, blockages, outlines, regions and fills. These stay disabled: they are LEF/DEF abstractions, not mask data, and writing them onto real layers would add shapes to the mask. The DEF has no FILLS today; when Stage D adds fill, it gets its own handling then.

**Alternative:** the PDK's pin datatypes (`<Metal>.pin`). Rejected for now: the measured DRC result used drawing-layer pins, and pin-purpose shapes matter only to LVS, which is not in scope.

### D4. `make gds` in a new `target/ihp13/klayout/klayout.mk`

`klayout.mk` follows `openroad.mk`'s pattern: `KLAYOUT ?= klayout` in `tools.mk`, `KLAYOUT_DIR`, and `GDS_DEF ?= $(TARGET_DIR)/openroad/out/$(PROJ_NAME).final.def` (an existing-file check fails early with the path). It writes `$(KLAYOUT_DIR)/out/$(PROJ_NAME).gds.gz` and `out/$(PROJ_NAME).stream.log`. `iguana.mk` includes it next to `openroad.mk`. The target is `gds` (with `gds-clean`); a DEF from a lane run is streamed with `make gds GDS_DEF=/path/basilisk.final.def`. `PROJ_NAME` stays `basilisk` (AGENTS.md constraint) and the top cell stays `iguana_chip` (`TOP_DESIGN`).

The stream is not a `run_pnr.sh` stage. It isn't OpenROAD, it doesn't checkpoint, and it should be rerunnable on any DEF without touching the P&R stage machinery.

### D5. KLayout from the upstream `.deb`, pinned, in `docker/all`

Ubuntu 24.04's apt KLayout is 0.28.16. IHP-Open-PDK's current KLayout DRC runner (Stage B) targets 0.29+, so the apt package would need replacing in a few days anyway. The final stage downloads klayout.de's Ubuntu 24.04 `.deb` for a pinned 0.30.x release, checks its SHA-256 in the Dockerfile, and installs it with `apt-get install ./klayout_*.deb`, which pulls its Qt5/Python/Ruby runtime dependencies. This works like the Verible tarball: a pinned upstream release and no builder stage. The exact 0.30.x pin is picked at implementation as the newest release at least two weeks old, checked against IHP-Open-PDK `ihp-sg13g2`'s stated KLayout requirement. It is then recorded in the Dockerfile comment and `docs/infra-plan.md`.

**Alternatives.**
- *apt `klayout`:* simplest, but too old for Stage B (above).
- *Build from source in a builder stage:* about 1 h of image build for no gain over the official `.deb`.
- *A separate sidecar image (the probe's `drc-probe-klayout`):* `pnr.yml`'s job runs in one container, so a second image means a `docker run` from inside it or a second job that downloads the 178 MB DEF artifact. One image is simpler.

### D6. Lane: a best-effort step after P&R, its own artifact

In `pnr.yml`'s `pnr` job, after the "Place and route" step and before the summary, a "Stream GDS" step runs `make gds` with `if: always() && hashFiles(DEF) != ''`, `continue-on-error: true` and a 30 min `timeout-minutes`. The summary step gains a "Layout (GDS)" line: size and empty IO instance count when it worked, "stream failed, see log" when it did not. An upload step publishes `basilisk-pnr-gds` (`.gds.gz` + stream log, 30-day retention, `if-no-files-found: ignore`). `basilisk-pnr-def` is unchanged.

The step runs on the VM inside the existing container. A separate GitHub-hosted job would have to download the DEF artifact and has 16 GB of RAM, against a stream that holds the 1.74 GB DEF and the merged layout in memory.

## Risks / Trade-offs

- **[A different KLayout than the probe's 0.28.16 streams the DEF differently]** → The acceptance check (spec: "Signoff DRC result unchanged against the probe") compares against the probe's result. First check: a cell and shape count per layer against the probe's `basilisk.gds`, which takes minutes. The full 7 h DRC sweep runs once, locally, before archiving.
- **[Memory on the VM]** → the probe's stream held roughly DEF + layout in memory. Measure the peak RSS in the first local run and record it. The VM's P&R peak (≈43 GB in `drt`) is much higher, and the stream runs after OpenROAD has exited.
- **[Image grows by KLayout + Ruby/Qt runtime]** → Most Qt5 libs are already present for the OpenROAD GUI. Accept a few hundred MB; record the size delta in the PR.
- **[`.deb` download disappears]** → The SHA-256 pin makes a changed file fail the build rather than silently differ. Published `newt-eda` tags keep working.
- **[The IO allow-list hides a real missing cell]** → The allow-list is an exact-name regex of the 12 legacy IO cells, not a pattern like `.*pad.*`. The log prints the allowed empties with instance counts, and the lane summary repeats the count.
- **[Pin labels on the wrong datatype]** → Take the text datatypes from the PDK's `.lyp`, not from memory, and check a few pins visually in KLayout with the PDK's layer properties.

## Migration Plan

No migration: there is no current GDS consumer. Order: image first (D5, published `:dev`), then the script and `make gds` (validated locally against `45365266924`'s DEF), then the lane step. The lane step runs for the first time on the next routed P&R run, which this change does not trigger. Rollback is reverting the commits; nothing upstream of `final` depends on them.
