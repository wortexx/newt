# Tasks

Cost legend: **[edit]** plain editing, no EDA tools; **[eda]** needs `newt-eda`/KLayout locally, minutes; **[long]** a long local run (hours); **[lane]** a P&R lane run on the VM. No task needs synthesis or a new P&R run: validation uses run `45365266924`'s DEF (`target/ihp13/openroad/out/ci-45365266924/def/basilisk.final.def`) and the probe's GDS from it (`target/ihp13/openroad/out/drc-probe/basilisk.gds`).

## 1. KLayout in the image

- [x] 1.1 **[edit]** Pick the KLayout pin (design D5): the newest klayout.de 0.30.x Ubuntu 24.04 `.deb` at least two weeks old that IHP-Open-PDK `ihp-sg13g2`'s KLayout scripts support. Record the version, URL and SHA-256. Verify: the URL's file matches the recorded SHA-256 (`sha256sum`).
- [x] 1.2 **[eda]** In `docker/all/Dockerfile`, download the `.deb`, check its SHA-256, and install it with `apt-get install -y ./klayout_*.deb`, then remove it. Comment the pin as the Verible block is commented. Verify: a local `make -C docker build` (or just the `all` stage) succeeds, and in the image `klayout -v` prints the pinned version and `klayout -b -r` of a 5-line `pya` script writes a GDS with no `DISPLAY` set.
- [x] 1.3 **[edit]** Add `klayout -v` to `docker/smoke-test.sh` (if it lists tool versions) and KLayout to `docker/README.md`'s tool list. Verify: `docker/smoke-test.sh` passes in the image built in 1.2.
- [x] 1.4 **[edit]** Add `KLAYOUT := klayout` to `tools.mk` with its URL comment, and to the `which` check list there if the other tools are on it. Verify: `make -n` of the tools check lists `klayout`.

## 2. Stream script

- [x] 2.1 **[edit]** Write `target/ihp13/klayout/src/sg13g2.map`: the probe's drawing layers (Metal1–TopMetal2, Via1–TopVia2) plus a text entry per metal for pin names, with each text datatype read from the PDK's `libs.tech/klayout/tech/sg13g2.lyp` (`<Metal>.text`) (design D3). Verify: every layer/datatype in the map appears in the `.lyp` under the expected name (a small grep/python check, its output pasted in the PR).
- [x] 2.2 **[edit]** Rewrite `target/ihp13/klayout/scripts/def2stream.py` as design D1: `-rd` inputs (`in_def`, `lef_files`, `gds_files`, `design_name`, `out_file`, `layer_map`, `io_allow`), probe-style `G<k>_` merge, empty check on the cells the top instantiates (allow-list → log name + instance count; anything else → error), deletion of extra top cells, pin text labels, timed log lines, exit status = error count. Keep the ORFS BSD notice for any code still derived from it; otherwise use this repo's SHL-0.51 header. Delete `target/ihp13/klayout/src/ihp130.lyt`. Verify: `python3 -m py_compile` passes, and `grep -rn ihp130.lyt` outside `openspec/` finds nothing.
- [x] 2.3 **[edit]** Write `target/ihp13/klayout/klayout.mk` (design D4): the LEF list mirroring `init_tech.tcl` (tech, stdcell, `future/sg13g2_iocell`, six SRAMs, `delay_line_D4_O1_6P000.abst.lef`); the GDS list (stdcell, delay line, six SRAMs); the IO allow-list as an exact-name regex of the 12 legacy IO cells; `GDS_DEF ?=` the flow's `$(PROJ_NAME).final.def` with an existing-file check; targets `gds` and `gds-clean` writing `out/$(PROJ_NAME).gds.gz` and `out/$(PROJ_NAME).stream.log`. Include it from `iguana.mk` after `openroad.mk`, and git-ignore `target/ihp13/klayout/out/`. Verify: `make -n gds` prints one `klayout -b` command with every input path existing (check with `ls`), and `make gds GDS_DEF=/nonexistent` fails with the path in the message.
- [x] 2.4 **[eda]** Run `make gds GDS_DEF=<45365266924 DEF>` in the image built in 1.2. Verify: exit 0; top cell `iguana_chip` and only one top cell; the log lists exactly the 12 IO cells as allowed empties with instance counts, no unexpected empties, and the count of empty macro sub-cells (the probe found 36); record wall time and peak RSS (`/usr/bin/time -v`).
- [x] 2.5 **[eda]** Negative checks on the same DEF. (a) Leave the delay-line GDS out of the list: the run must exit non-zero and name `delay_line_D4_O1_6P000`. (b) Drop the renaming (a temporary local edit, not committed): the merge must visibly change a `VIA_Via1_YX_so` or `RM_IHPSG13_1P_BITKIT_CELL` definition, which shows the rename is load-bearing. Verify: both outcomes as described, noted in the PR.
- [x] 2.6 **[eda]** Compare against the probe's GDS: per-layer shape counts and the cell list of the new GDS against `drc-probe/basilisk.gds` (a small `pya` script, scratch). Expected: identical except the added text labels, and cells renamed only where the `G<k>_` indices differ. Verify: the comparison output, pasted in the PR, has no unexplained difference.
- [x] 2.7 **[eda]** Open the GDS in KLayout with the PDK's `sg13g2.lyp` and check a corner of the core, one SRAM, one delay line and 3 top-level pin labels. Save one screenshot of the full die. Verify: labels sit on the pins, on the text layer of their metal; the screenshot is attached to the PR.
- [x] 2.8 **[long]** Run the probe's full-die DRC sweep (`drc-probe/gen/sweep.sh` + `merge.py`, ~7 h) on the new GDS. Verify: the merged non-density result matches the 2026-11-24/25 result exactly (spec scenario "Signoff DRC result unchanged against the probe"). Can run in parallel with group 3.
- [x] 2.9 **[edit]** Document it: a "GDS stream" section in `docs/pnr-pipeline.md` (inputs, `make gds [GDS_DEF=…]`, outputs, the IO allow-list and why the pads are empty, the rename rule), and `make gds` in `AGENTS.md`'s command reference. Verify: the documented command is the one run in 2.4.

## 3. P&R lane

- [x] 3.1 **[edit]** In `.github/workflows/pnr.yml`'s `pnr` job, add the "Stream GDS" step after "Place and route" (design D6: runs only when `basilisk.final.def` exists, `continue-on-error: true`, `timeout-minutes: 30`, `make gds`). Add a "Layout (GDS)" line to the stage-status summary (size + allowed-empty IO instance count, or "stream failed, see log") and an "Upload GDS" step (`basilisk-pnr-gds`: `.gds.gz` + stream log, 30 days, `if-no-files-found: ignore`). Verify: `actionlint` on the file is clean, and the step conditions read as in the spec scenarios ("Routed run publishes a GDS", "Stream fails on a routed run", "No DEF, no stream").
- [x] 3.2 **[eda]** Dry-run the summary snippet locally against the 2.4 outputs and against a missing/failed stream log. Verify: the three summary variants print as intended.
- [x] 3.3 **[edit]** Update `docs/infra-plan.md` Phase 19 Stage A: tick the items done, record the KLayout pin, the 2.4 timing/memory and the 2.8 DRC result. Verify: the Stage A checklist matches what was done.

## 4. Integration

- [ ] 4.1 **[lane]** After the image change is merged and `:dev` is published, the next routed P&R run on `main` (no dedicated run: piggyback on the next one that is dispatched for other reasons, or resume `45365266924` from `drt` with `PNR_STOP_AFTER=final` if one is needed before archiving) publishes `basilisk-pnr-gds`. Verify: the artifact downloads, `make gds` on that run's DEF locally gives the same per-layer counts, and the summary line is present.
- [x] 4.2 **[edit]** `openspec validate stream-final-gds --strict` passes. Verify: command output.

## Workflow follow-up

- Archive the change after 4.1 and review; sync `chip-finishing`, `eda-tooling-image` and `ci-pipeline` specs.
- Stage B (`seal-and-drc-gds`) starts from this GDS.
