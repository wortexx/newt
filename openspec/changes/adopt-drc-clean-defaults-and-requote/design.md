# Design

## Context

See proposal.md (Why) for the motivation. The current state:

- **Flow defaults** (`target/ihp13/openroad/scripts/pnr/common.tcl`): `pnr_die_scale` 1.10, `pnr_gpl_density` 0.65, `pnr_grt_metal2_adjust` 0.30, `pnr_grt_sram_metal5_adjust` 0. Each is overridable by its `PNR_*` variable.
- **`drt.tcl`** runs full `repair_antennas` unless `PNR_SKIP_ANTENNA_REPAIR=1`, in `PNR_ANTENNA_REPAIR_MODE` (default `full`).
- **Lane defaults** (`.github/workflows/pnr.yml`'s `pnr` step):
  - an empty `antenna_repair` maps to `PNR_SKIP_ANTENNA_REPAIR=1`;
  - an empty `drt_end_iter` maps to 5;
  - the `start` job accepts `antenna_repair` empty, `1` or `jumper`.
- **The measured chain:**
  - P2 run `38931700180` (`0f916ba`) built `floorplan` through `cts` at die 1.25 and density 0.50.
  - `39696194006` (`b7b8ff3`) ran `grt` with Metal2 0.60 and Metal5 0.55.
  - `39906592139` ran `drt` with jumper repair and 28 iterations: 8 router violations, 8,627 / 11,287 antenna nets / pins.
  - Between `0f916ba` and `main`, the flow through `cts` differs only by the cell-padding procs, which are no-ops at the default 0 sites (checked 2026-10-24).
- **The requote rule** (`openspec/specs/sha3-evaluation`): both runs use the same flow revision, die and flow inputs, and both are legal after `dpl` and `cts`.
- **The reference branch** `pnr-reference-no-arms` (`fe8e84d`) differs from its base `52978e1` in four files (`Bender.yml`, `hw/iguana_pkg.sv`, `hw/iguana_soc.sv`, `project-synth.mk`). Nothing under `hw/`, `Bender.*` or `target/ihp13/yosys` has changed on `main` since `52978e1`.
- **`scripts/sha3_ppa.py`** parses each run's `pnr_status.log`, its floorplan `Die:` line, the legality lines and `basilisk.grt.rpt`. Its flow sentence hard-codes `stop_after=grt`.

## Goals / Non-Goals

**Goals:**

- A scheduled or input-less run reproduces the near-clean layout with no dispatch inputs.
- The thesis comparison comes from two runs that differ only in the SHA-3 hardware and that both route.

**Non-Goals:**

- Making diode repair work. That is change `finish-antenna-diode-repair`; full repair only stays reachable on request.
- Signoff DRC, metal fill, or the PDN lever over the SRAMs.
- Re-choosing the coprocessor's rounds per cycle (R) from placed timing. That stays a follow-up in `docs/infra-plan.md`.

## Decisions

### D1. Which defaults move, and where

| setting | old | new | where |
|---|---|---|---|
| die scale | 1.10 | 1.25 | `common.tcl` `pnr_die_scale` |
| `gpl` density | 0.65 | 0.50 | `common.tcl` `pnr_gpl_density` |
| Metal2 hold-back | 0.30 | 0.60 | `common.tcl` `pnr_grt_metal2_adjust` |
| SRAM Metal5 hold-back | 0 | 0.55 | `common.tcl` `pnr_grt_sram_metal5_adjust` |
| antenna repair | skipped (lane), full (local) | jumper-only | `pnr.yml` mapping, `drt.tcl` default mode |
| `drt` iteration budget | 5 (lane), 40 (local) | 28 (lane) | `pnr.yml` default |

- *Why in `common.tcl`, not as lane inputs:* the specs describe the input as "empty keeps the flow's default". Putting the values in the flow makes local `make run-pnr` and the lane agree.
- *Why the budget stays a lane default:* `drt.tcl`'s local default of 40 is `chip.tcl`'s historical value. 28 fits the 24 h timeout with margin, and the lane is where that timeout applies.
- *`antenna_repair` values:*
  - empty → jumper-only (new default);
  - `jumper` → jumper-only;
  - `1` → full repair, kept for existing dispatch habits;
  - `skip` → no repair (new).

  The `start` job's check accepts exactly these four values. *Alternative:* `0` for skip. Rejected, because `0` reads as "no change" next to the other numeric inputs' "0 = OpenROAD default".
- Each changed default keeps its comment, which states the measured run behind it, as the existing comments do.

### D2. Both-arms side: a fresh input-less run on `main`

Dispatch `pnr.yml` on `main` with no inputs, once D1 has merged. It is the requote's both-arms run, and it also checks D1: with no inputs it should behave like the measured chain. Compare it with the chain:

- `grt` WNS (−12.05 ns) and overflow (7,153);
- the router count after iteration 28 (8);
- the antenna counts (8,627 / 11,287);
- `DPL-0009` utilization after `cts` (45.6 %).

- *Why not reuse the chain:* it spans three commits and dispatch inputs. The spec requires the same flow revision and inputs on both sides, and the reference would be one run at one commit.
- *The comparison is a report, not a gate.* Detailed routing is deterministic from a given checkpoint (run `39244019401` reproduced all 33 counts), but whether global placement reproduces `38931700180`'s placement bit for bit has not been checked. A difference is recorded and explained. The run still serves as the requote if it is legal and complete.

### D3. Reference side: rebase, run with no inputs, check the netlist by its synth key

- **Rebase:** rebase `pnr-reference-no-arms` onto the `main` commit D2 ran on. Verify with `git diff <that commit> --stat`: the same four files.
- **Run:** dispatch `pnr.yml` on the branch with no inputs. The `pnr` job synthesizes the branch itself, which takes about 2.5 h on a VM-cache miss.
- **Netlist check:** compare this run's `synth-key.txt`, as uploaded with its checkpoints, with run `38772313345`'s.
  - Equal keys mean the synthesis inputs are the ones task 3.2 of `requote-sha3-pnr-legal-placement` already compared against the pre-coprocessor reference (cells −0.43 %, area −0.10 %, flip-flops −0.02 %, explained). That comparison carries over.
  - Different keys need a `synth.yml` run on the branch and a fresh metrics comparison. Stop and ask before dispatching it.
- *Alternative:* always dispatch `synth.yml` first, as last time. Rejected as about 2 h of VM time to recompute a known result. The key check detects any change to the netlist's inputs.

### D4. Both runs go through `final`, with no `stop_after`

Both runs use only defaults, so "same flow inputs" holds by construction, and both produce a routed design and an antenna count. The quoted timing and power stay at `grt`, labelled "before post-route repair", as today: `grt_repair` stays skipped by default. The thesis gains router and antenna counts for both sides.

- If one run's `drt` fails or times out, its `grt` figures can still be compared (both gates passed). The section then says that run has no routed design, as the sha3-evaluation delta requires. The requote then proceeds only after the user decides.

### D5. Generator: settings from the logs, routed outcome from the status

`scripts/sha3_ppa.py`:

- **Flow sentence:** built from each run's logs instead of the hard-coded text:
  - the `Die:` line;
  - `Global placement target density:` in `pnr_gpl.log`;
  - `Global routing layer adjustment:` and `SRAM Metal5 adjustment:` in `pnr_grt.log`;
  - the `drt` status detail (`droute_end_iter=<n> antenna=<mode>`).
- **Comparability check (`pnr_comparable`):** additionally refuses two runs whose parsed settings differ, naming the setting. This enforces "same flow inputs".
- **Routed outcome:** from the `drt-violations` and `drt-antenna` status rows. A `none` row prints as "no routed design" or "no antenna count", never as zero.
- Every other figure, including the uniform-activity power split and worst-path attribution, keeps its current source.

### D6. How the results docs carry the change

- `docs/results/sha3-ppa.md` is regenerated from the new pair, with the same non-P&R inputs as today.
- `docs/results/sha3-evaluation.md`:
  - the new figures become the current ones;
  - the 1.10-die pair (`38395368038` / `38772313345`, −8.96 / −8.39 ns, 19.96 ns) moves to a dated "earlier flow settings" note. It states the settings and why they changed: that layout did not route. It is not labelled superseded-for-illegality, because it was legal;
  - the existing superseded illegal-placement note stays as it is.
- `docs/infra-plan.md`: the "Next change" item is ticked with both run IDs, and the §0 "Basilisk WNS" row gets the new figures.

## Risks / Trade-offs

- **The achieved period worsens by about 3 ns**, and with it every energy-per-byte figure. That is the stated price of a routable layout; the "earlier flow settings" note keeps the 1.10 figures visible for the trade-off.
- **The input-less run may not reproduce the chain** (D2). The cause would be `gpl` nondeterminism or an unnoticed difference before `cts`. It is recorded, and a gross difference is a stop-and-ask: a router count above 1,000, or WNS more than 1 ns off.
- **The reference's `drt` may not converge in 28 iterations.** It is a smaller netlist on the same die, so less congested, but it is not measured. → D4's fallback.
- **Resuming old checkpoints now silently mixes settings.** → `docs/pnr-pipeline.md` says to set the old values explicitly when resuming a pre-change run. A code guard (for example, recording settings in the checkpoint) is out of scope.
- **Weekly runs get longer.** The two drivers: 1.25-die placement, and 28 iterations, although on this die they are faster than the old 5 on the 1.10 die (7 h against about 15.5 h). The measured total is about 16 h, inside the 48 h job ceiling.

## Migration Plan

1. Merge D1 and D5 (no VM cost). The next scheduled Friday run uses the new defaults.
2. Dispatch D2, then D3. The `pnr` concurrency group queues them one after the other.
3. Regenerate and rewrite the docs (D6), then open one PR.
4. Rollback: revert the D1 commit. Old-default runs then reproduce the previous layout, and the docs' earlier-settings note still names its runs.
