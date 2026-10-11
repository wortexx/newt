# Bridge wrong-direction route guides (change `bridge-wrong-way-route-guides`) — tasks

Tags:

- **[edit]**: plain file editing, checked locally (Tcl parse, `bash -n`, `shellcheck`,
  `actionlint`).
- **[eda]**: needs OpenROAD from the `newt-eda` image locally (minutes, on the downloaded `grt`
  checkpoint of run `38094932339`).
- **[long-run]**: a P&R lane run on the self-hosted Azure VM. Each one is dispatched **only after
  the user approves it**.

## 1. Bridge step (design D1–D3)

- [x] 1.1 **[edit]** In `scripts/pnr/common.tcl`, add the setting and the helper:
  - `pnr_bridge_guides` from `PNR_BRIDGE_GUIDES`: empty means 1, `0` turns the bridge off, and
    anything else is a Tcl `error`. The comment cites this change and Phase 11.
  - `pnr_bridge_wrong_way_guides`:
    - collects every guide on routing levels 2–6 that spans more than one gcell step (from
      `dbGCellGrid`) against its layer's `getDirection`;
    - then creates a copy on level L+1 (L−1 for level 6), with the new layer as via layer;
    - reports `Bridged <n> wrong-direction guides on <m> nets`.

  Verify: Tcl parse of `common.tcl`.
- [x] 1.2 **[edit]** In `scripts/pnr/drt.tcl`, after `pnr_apply_routing_layers`, call the helper
  when `pnr_bridge_guides` is 1. Otherwise report `Guide bridging off (PNR_BRIDGE_GUIDES=0)`.
  Document `PNR_BRIDGE_GUIDES` in `run_pnr.sh`'s header. Verify: Tcl parse and `bash -n`.
- [x] 1.3 **[eda]** Run the helper locally in `newt-eda` on the `grt` checkpoint of run
  `38094932339`, with `set_routing_layers` as in `drt`. Verify:
  - `clknet_12_3602__leaf_i_iguana_soc.clk_i_regs` gains exactly one guide, Metal3
    (6337800,4599000)-(6344100,4611600);
  - the totals match probe 5 (1,264 guides on 639 nets);
  - a second call with `PNR_BRIDGE_GUIDES=0` adds nothing;
  - `PNR_BRIDGE_GUIDES=x` is rejected.
  — **done.** Default: `Bridged 1264 wrong-direction guides on 639 nets (gcell step 6300 dbu)`;
  the net went 165 → 166 guides, the new one `Metal3 6337800 4599000 6344100 4611600`, via layer
  Metal3. `PNR_BRIDGE_GUIDES=0`: `Guide bridging off`, 165 guides. `x`: rejected. 737 s under
  x86 emulation on the Mac; probe 5 did the same walk in under a minute on the VM.

## 2. `drt` budget (design D4)

- [x] 2.1 **[edit]** In `.github/workflows/pnr.yml`, set `PNR_TIMEOUT_DRT=86400` on the
  `run_pnr.sh` line, with a comment next to the `PNR_DRT_END_ITER` one: about 2.5 h per
  iteration on the enlarged die, and a timeout loses the stage's output. Verify: `actionlint`.
- [x] 2.2 **[edit]** `docs/pnr-pipeline.md`: in the stage table, `drt` bridges wrong-direction
  guides first. In the timeouts paragraph, `drt` is 24 h in the lane. Verify: the text matches the
  scripts.

## 3. Validate on real data (Migration Plan step 2)

- [ ] 3.1 **[long-run]** With the user's approval, dispatch `pnr.yml` from the branch with
  `resume_from_run=38094932339` and no other inputs. Verify:
  - the `drt` log has the `Bridged … guides on … nets` line;
  - guide processing passes (`Start track assignment`, no `DRT-0218`);
  - `pnr_status.log` shows `drt` ok or a bounded failure.
- [ ] 3.2 Record here: the violation count per iteration (`DRT-0199`, iterations 0–7), time per
  iteration, `drt` total, `final`'s outcome, whether `basilisk-pnr-def` holds
  `basilisk.final.def`, and the run's `drt`-stage DRC report size.
- [ ] 3.3 **[edit]** Record 3.2 in `docs/infra-plan.md` Phase 11, under the 2026-10-11 `DRT-0218`
  finding: the fix, the run, the violation trajectory, and whether a DEF now exists. Verify:
  Phase 11 links this change and the run ID.

## 4. Integration

- [ ] 4.1 Run `openspec validate bridge-wrong-way-route-guides --strict`, and map each `pnr-flow`
  scenario to evidence: the first two from 1.3 and 3.1, the third from 1.3. Verify: validation
  passes, and each scenario cites a run or a local check.
