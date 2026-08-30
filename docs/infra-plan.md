# newt — CI & Infrastructure Plan

**Project:** `newt` — a fork of Basilisk (`pulp-platform/cheshire-ihp130-o`) adding custom
instructions for a cryptographic (SHA) coprocessor on CVA6 / Cheshire, targeting IHP's
130 nm open-source PDK.

**Status:** planning. This is a living document — update it as phases complete.

**Date started:** 2026-08-29

---

## 0. Context & constraints (learned from a full end-to-end backend run)

| Fact | Implication |
| --- | --- |
| Upstream repo dormant since 2024-10; Docker image built 2024-08-22 | Nobody upstream will refresh tooling — we own it. |
| yosys is a **custom fork** (`github.com/phsauter/yosys` @ `3ce5059`) | Do **not** rebase onto upstream yosys unless it actively blocks us. |
| OpenROAD is upstream (`589dee1c8`, ~mid-2024) | Safe to bump to a recent release. This is where all backend instability was. |
| Simulation is **Questa-only** (`iguana.mk` → `questa-2022.3 vsim`); no Verilator flow | **Critical-path blocker for RTL CI.** Must add Verilator. |
| Dev machine has 31 GB RAM; synth peaks ~35 GB | Basilisk synth needs a >64 GB box or a swap file. |
| Stock `chip.tcl` does not complete unattended | `remove_buffers` segfaults ~1/3 runs (retry); post-route `repair_timing -repair_tns 100` loops forever + segfaults on a design that can't close timing. |
| Basilisk WNS ≈ −2.5 ns vs 6 ns target | Design does not close timing in the open flow (known / accepted). |
| CVA6 CV-X-IF present but disabled: `CVA6ConfigCvxifEn = 0`; Cheshire ties off `cvxif_req_o` / `cvxif_resp_i`, `cheshire_pkg CvxifEn : 0` | The integration seam already exists; needs enabling + un-tying. |

### ISA integration — open decision (does not block infra)

Choosing between:

1. **CV-X-IF custom coprocessor** — own opcodes via CVA6's eXtension interface; `.insn`
   inline-asm wrappers (no compiler patch). Needed for SHA-3/Keccak.
2. **RISC-V `Zknh` standard extension** — `sha256sig0/1`, `sha256sum0/1`, `sha512*`;
   `-march=rv64gc_zknh` already in GCC/LLVM. SHA-2 only.

Both modify **CVA6 + Cheshire** and both need the simulator to carry the new instructions,
so the infra plan is identical. MMIO-accelerator option dropped from the critical path
(revisit only if 1 and 2 both prove too invasive).

**Toolchain consequence:** keep option 2 open → `newt-eda` must ship
**riscv64 GCC ≥ 13 / binutils ≥ 2.40**.

---

## Phase ordering

```
Phase 0  ──►  Phase 1 (newt-eda image) ─┐
             Phase 2 (Verilator flow)  ─┴─►  Phase 3 (fast CI) ──► Phase 4 (synth CI) ──► Phase 5+6 (P&R + Azure)
                                                                └►  Phase 7 (coprocessor RTL, ongoing, parallel)
                                                                └►  Phase 8 (svase→yosys-slang, exploratory, parallel)
```

**Do Phase 2 first among the technical work** — it is the long pole; everything meaningful
in CI depends on a free simulator. Phases 5–6 (Azure) come last: highest effort, lowest run
frequency; GitHub large runners cover synth until then.

---

## Phase 0 — Repository setup

- [x] Fork `pulp-platform/cheshire-ihp130-o` → `wortexx/newt`
      (<https://github.com/wortexx/newt>).
- [x] On the dev checkout: `origin` = `git@github.com:wortexx/newt.git`,
      `upstream` = pulp-platform; `main` tracks `origin/main`.
- [x] `.gitignore`: added `target/ihp13/backend-run/`, `target/ihp13/*/out/`,
      `target/ihp13/openroad/{save,reports}/` (`.bender`, `*.log`,
      `target/sim/vsim/work/` were already covered upstream). Pushed to fork.
- [x] Branch protection on `main`: PR required (0 approvals — solo repo), status checks
      required-but-empty (add Phase 3 job names once CI exists), no force-push/deletion.
- [x] Add `docs/` (this file). CODEOWNERS dropped — pointless for a solo repo
      (recreate as `.github/CODEOWNERS` with `* @wortexx` if collaborators join).
- [ ] **Naming:** keep `PROJ_NAME` / `RTL_NAME = basilisk` internally for now — many scripts
      hardcode it (`basilisk.sdc`, checkpoint/report paths). Optional dedicated rename PR later.
- [ ] **Dependency strategy** for modified IP: fork `cheshire` (un-tie cvxif port) and,
      when needed, `cva6` (`CvxifEn=1` / `Zknh`); point `Bender.yml` at the forks + commits.
      Prefer forks over `pickle/patches/` for anything beyond a one-line change.

## Phase 1 — `newt-eda` tooling image

Derive from the existing `docker/` multi-stage layout; do not rewrite from scratch.

- [ ] `DOCKER_BASE_IMG`: `almalinux:8.9` → `ubuntu:24.04` in all of
      `docker/{pickle,yosys,openroad,riscv64}/Dockerfile`; port `packages.txt` yum → apt.
- [ ] **OpenROAD**: bump `OR_COMMIT` to a recent tagged release.
- [ ] **riscv64 toolchain**: bump to GCC ≥ 13 (keeps `Zknh` option open).
- [ ] **Keep pinned**: yosys fork, morty `v0.9.0`, svase, sv2v `v0.0.11`, bender `v0.27.4`.
- [ ] **Add**: Verilator (v5.x stable), `verible` (lint/format).
- [ ] Publish to **GHCR**: `ghcr.io/wortexx/newt-eda:<yyyy-mm-dd>-<sha>` + moving `:dev`.
- [ ] Workflow: rebuild + push image on any `docker/**` change.
- [ ] **Adoption gate:** run `make synth-all` on *unmodified* basilisk in the new image;
      diff cell count / area / WNS against the 2024 baseline
      (`target/ihp13/yosys/reports/basilisk_area.rpt`). Small deltas from the OpenROAD bump
      expected; investigate large ones. Keep the 2024 image as fallback.
- [ ] Expect 2–3 days adapting `chip.tcl` to newer OpenROAD command APIs
      (`remove_buffers` now requires instance args; `repair_timing` / `global_route` /
      `detailed_route` flags moved; GUI / `save_image` changes).

## Phase 2 — Verilator simulation flow  *(critical path)*

Questa stays as a local-only waveform-debug target.

- [ ] Add `bender script verilator` + a Verilator build to `iguana.mk`
      (mirror `ig-sim-rtl`; reuse `BENDER_SIM_TARGETS`). Crib from Cheshire / CVA6 upstream
      Verilator support.
- [ ] Port `SIM_PRE_COMPILE` (`BOOTMODE` / `PRELMODE` / `BINARY`) to Verilator plusargs.
- [ ] **Green light:** `sw/tests/helloworld.spm.elf` boots and prints under Verilator, exit 0.
- [ ] Coprocessor **unit testbench** (Verilator or cocotb) driving the CV-X-IF / instruction
      interface directly with NIST KAT vectors.
- [ ] Fallback if full-SoC Verilator stalls (hyperbus / DRAM models are the usual snag):
      ship the unit TB first; do full-SoC sim in the synth lane later.

## Phase 3 — CI fast lane (GitHub-hosted, every PR + push)

Container `newt-eda`; runner `ubuntu-latest` (or an 8-core larger runner if sim is slow).

| Job | What | ~time |
| --- | --- | --- |
| `lint` | `bender check`; `verible-verilog-lint` + `verilator --lint-only` on changed RTL | ~2 min |
| `sw` | build test binaries incl. SHA KAT programs (riscv64 gcc) | ~3 min |
| `sim-unit` | coprocessor TB — full NIST KAT set | 5–15 min |
| `sim-soc` | Verilator: Cheshire boot + one KAT through the new instructions | 15–40 min |
| `synth-coproc` | yosys synth of the coprocessor module only → area + Fmax; fail on regression vs a checked-in budget file | 5–10 min |

## Phase 4 — CI synth lane

Triggers: nightly + `workflow_dispatch` + label `full-synth`.

- [ ] `make ig-hw-all && make pickle-all && make synth-all` → upload netlist + reports.
- [ ] Post summary: cell count, area, DFF count, WNS vs baseline.
- [ ] Run on a **GitHub large runner** (64 GB / 16-core, fits the 6 h cap) first — no infra.
      Move to the self-hosted VM only if the large runner proves insufficient.

## Phase 5 — CI P&R lane (self-hosted Azure agent)

Triggers: weekly + `workflow_dispatch` + tags/releases.

- [ ] `start` job (GH-hosted): `az vm start`.
- [ ] `pnr` job (`runs-on: [self-hosted, newt]`, `timeout-minutes: 2880`):
      run a **checkpoint-resume flow with `repair_timing` skipped or bounded**
      (`-repair_tns 20 -max_buffer_percent 15`) — do **not** run stock `chip.tcl` unattended.
      Reference implementation: `target/ihp13/openroad/scripts/resume_no_repair_timing.tcl`.
      Wrap `remove_buffers` with one retry.
- [ ] `stop` job (`if: always()`): `az vm deallocate --no-wait`.
- [ ] Artifacts: DEF + reports → GitHub artifacts; checkpoints (~1.5 GB each) → Azure Blob
      with a 30-day lifecycle rule.

## Phase 6 — Azure infrastructure as code

- [ ] **Terraform or Bicep**: resource group; `Standard_E16ds_v5` (created deallocated);
      storage account; user-assigned managed identity; **OIDC federated credential**
      (GitHub → Azure, no stored secrets); NSG; budget alert.
- [ ] **Golden VM image** (Packer or manual capture): Ubuntu + Docker +
      `docker pull ghcr.io/wortexx/newt-eda:dev` + Actions runner installed as a service
      (auto-reconnects on boot). Eliminates cold-start pull cost.
- [ ] Runner registration: GitHub App (preferred) or PAT in Key Vault.
- [ ] Guardrails: auto-deallocate on job end; `concurrency` group of 1;
      **spot VM for the synth lane only** (P&R stays on-demand — `detailed_route`
      does not checkpoint mid-run, so an eviction there loses the whole phase).

## Phase 7 — Coprocessor scaffolding  *(parallel track, not infra)*

- [ ] `hw/newt_sha_*.sv` + `Bender.yml` entry.
- [ ] Config flip: `CVA6ConfigCvxifEn=1` (+ Cheshire `CvxifEn`) or `Zknh` ALU path.
- [ ] Un-tie Cheshire `cvxif_*` port (fork).
- [ ] `sw/tests/sha_kat_*.c` — NIST CAVP known-answer vectors.
- [ ] Unit testbench (Phase 2).
- [ ] Decision needed from `custom-isa-extension.md`: mechanism (1 vs 2) + which hashes
      (SHA-256 / SHA-512 / SHA-3).

## Phase 8 — Replace svase+sv2v with `yosys-slang`  *(exploratory, not blocking)*

`svase` (github.com/pulp-platform/svase) is now archived upstream — no more fixes will land.
It's a thin wrapper around **slang** (SV compiler frontend): parse+elaborate with slang,
re-emit plain SystemVerilog for `sv2v` to downgrade further for yosys. Slang itself has no
first-class "re-emit legal SV" mode, which is the whole reason svase exists as a separate tool.

Three options, in increasing order of payoff and effort:

1. **Fork svase** (matches the project's existing pattern for yosys/cheshire/cva6) — lowest
   effort, keeps today's `morty → svase → sv2v → yosys` pipeline shape unchanged. Archival
   mainly means no upstream fixes; svase pins its own slang version, so it won't break on its
   own.
2. **Adopt `yosys-slang`** (antmicro/povik's yosys plugin using slang as yosys's native
   SystemVerilog frontend) — potentially removes **both** svase and sv2v from the pickle
   chain, not just svase, since yosys would consume slang-elaborated SV directly instead of
   needing it pre-flattened to old-style Verilog. Meaningfully better architecture, bigger
   lift: needs validation against this design's parameterization/macros/attributes, and
   changes `target/ihp13/pickle/pickle.mk`'s shape.
3. **Custom slang-based re-emitter** — reimplementing svase's function from scratch. Not
   recommended; more work than (2) for less benefit.

- [ ] Prototype `yosys-slang` against unmodified Basilisk RTL; confirm it handles this
      design's constructs before committing to it.
- [ ] If it works: dedicated OpenSpec change (its own proposal/design/tasks) to replace the
      `svase`+`sv2v` pipeline stages — this is a real architecture change to the synthesis
      frontend, not a drop-in tool swap folded into another change.
- [ ] If it doesn't: fall back to forking svase (option 1) so the pin stops depending on an
      archived, unmaintained upstream.
- No critical-path dependency on this phase; `svase f5f5290` stays pinned and untouched
  everywhere else until this is prototyped and decided.

---

## Risks

| Risk | Mitigation |
| --- | --- |
| Questa → Verilator port is hard (Cheshire TB, hyperbus / DDR models) | Start with the coprocessor unit TB; accept synth-lane-only full-SoC sim initially |
| OpenROAD bump breaks `chip.tcl` command APIs | Budget 2–3 days in Phase 1; keep the 2024 image as fallback |
| Golden-image drift on every tool bump | Automate capture in Packer (Phase 6) |
| Azure cost creep | Spot for synth; deallocate always; budget alert. Est. ~$50–150/mo depending on P&R cadence |
| `detailed_route` never converges on the modified design | It is congestion-bound at 63 % util even for stock Basilisk; treat a clean route as a stretch goal, not a gate. Consider a secondary easier PDK (Sky130) for fast QoR during development |

---

## Appendix A — observed resource profile (stock Basilisk, this hardware)

| Phase | RAM peak | Parallelism | Wall time |
| --- | --- | --- | --- |
| yosys synthesis | ~30–35 GB | mostly 1–2 threads (ABC) | ~2.5 h (with swap) |
| OpenROAD floorplan → CTS → global route | 8–15 GB | 8–12 threads | ~2 h |
| OpenROAD `detailed_route` | ~26–30 GB | ~12–32 threads | many hours; did not converge (700 k → 516 k DRC violations over 2 iterations before manual stop) |
| Disk | — | — | ~1.5 GB per checkpoint × ~13; budget 200 GB |

Netlist: 127 MB, ~713 k cells, ~89 k flip-flops, yosys `CHECK` reports 0 problems.
Die: 6.23 × 5.48 mm, 63 % utilization.

## Appendix B — backend gotchas to bake into CI scripts

1. Regenerate `basilisk.sources.json` in-container — the checked-in copy has absolute host
   paths that break morty inside the container.
2. `make synth-all` does not trigger a pickle rebuild; `make run-yosys-hier` does (phony
   `HW_CONF_TARGETS` deps) and its hierarchical flow is **broken** on this design
   (`hierarchy -check` fails on wrapper-only partition files). Use monolithic `synth-all`.
3. OpenROAD headless: `QT_QPA_PLATFORM=offscreen`, `openroad -exit scripts/…tcl`, no `-gui`.
   `set_display_controls` INFO warnings are harmless; `save_image` still works.
4. After `load_checkpoint`, re-apply GRT layer config before `global_route`
   (`set_routing_layers -signal Metal2-TopMetal1 …` + the two
   `set_global_routing_layer_adjustment` lines from `chip.tcl`) or `detailed_route`
   fails with `DRT-0155` (guides on TopMetal2).
5. Use a dedicated long-lived container (`docker run -d … sleep infinity`) for multi-hour
   jobs — the docker-compose container exits on its own.
