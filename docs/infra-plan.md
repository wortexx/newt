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
| yosys was a **custom fork** (upstream 2024-04 + 3 commits on `abc.cc`) | **Retired 2026-09-17**: now upstream **v0.69**, pinned by release tag in `docker/yosys/Dockerfile`. The fork's `-liberty_args` landed upstream in v0.66, and v0.67+ is the first yosys with the slang frontend built in, which Phase 8 needs. Bump the tag only via a change that re-runs the synthesis adoption gate. |
| OpenROAD is upstream (`589dee1c8`, ~mid-2024) | **Bumped to `2c56926` (2026-08-27) in `newt-eda`.** "Safe to bump" held, but the 2.5-year API gap needed real porting work: `initialize_floorplan -sites`→`-site`, `detailed_route`'s `-bottom/-top_routing_layer` now hard errors (DRT-0509/0510, use `set_routing_layers`), PDN zero-instance crashes, per-process `set_wire_rc`/`estimate_parasitics`/`set_thread_count`. **Lesson: check a command's proc body, not its `define_cmd_args`** — the deprecated flags are still declared and parsed, and only the body rejects them. Backend instability was *not* all OpenROAD: see the routability blocker in Phase 11. |
| Simulation is **Questa-only** (`iguana.mk` → `questa-2022.3 vsim`); no Verilator flow | **Critical-path blocker for RTL CI.** Must add Verilator. |
| Dev machine has 31 GB RAM; synth peaks ~35 GB | Basilisk synth needs a >64 GB box or a swap file. |
| Stock `chip.tcl` does not complete unattended | Still true, but **the specific failure modes did not reproduce**: across 10 real P&R runs `remove_buffers` **never crashed once** (the "~1/3 runs" figure is unsubstantiated in this environment — the retry was ultimately verified by deliberate fault injection, not by a real crash). `repair_timing` looping forever did reproduce, and post-route repair is now skipped entirely. The real unattended blockers turned out to be elsewhere: `repair_antennas` hanging ~14h single-threaded, and global route's congestion iterations. |
| Basilisk WNS ≈ −2.5 ns vs 6 ns target | Design does not close timing in the open flow (known / accepted). **Caveat for any PPA number quoted from the CI lane**: with `grt_repair` skipped (Phase 5), measured WNS at `grt` is **−14.76**, not −2.5 — post-route repair is exactly what closes that gap. Restore a bounded `grt_repair`, or requote the baseline, before using lane output as thesis PPA data. |
| CVA6 CV-X-IF present but disabled: `CVA6ConfigCvxifEn = 0`; Cheshire ties off `cvxif_req_o` / `cvxif_resp_i`, `cheshire_pkg CvxifEn : 0` | The integration seam already exists; needs enabling + un-tying. |

### ISA integration — decided 2026-10-01: SHA-3 via CV-X-IF (+ MMIO comparison arm)

**Decision:** option 1 with SHA-3/Keccak. The instructions are `shatr` (one Keccak-f round, after arXiv:2508.20653) plus `kclr`/`kxor`/`krd`/`kperm`, on `custom-1` in a CV-X-IF coprocessor, with no CVA6 RTL change. A memory-mapped Keccak accelerator is built as a **comparison arm**, not as a fallback. Its job is the measured ISE-vs-MMIO crossover. `Zknh` was rejected: its speedup (~1.4–2.3×) and its hardware (~2.5k gates, no flip-flops) are too small to give a measurable PPA result on this flow. Change: `openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/` (design D1). Decision record: [ADR-0003](adr/adr-0003-sha3-via-cvxif.md).

The options as they were framed:

1. **CV-X-IF custom coprocessor** — own opcodes via CVA6's eXtension interface; `.insn`
   inline-asm wrappers (no compiler patch). Needed for SHA-3/Keccak.
2. **RISC-V `Zknh` standard extension** — `sha256sig0/1`, `sha256sum0/1`, `sha512*`;
   `-march=rv64gc_zknh` already in GCC/LLVM. SHA-2 only.

Both modify **CVA6 + Cheshire** and both need the simulator to carry the new instructions,
so the infra plan is identical. The MMIO accelerator was originally dropped from the critical path.
It returns as the comparison arm above, and it carries no infra consequence beyond the
`AxiExtNumSlv` port.

**Toolchain consequence:** option 1 needs no toolchain support. The custom opcodes are emitted with
`.insn r` and assemble on any binutils. The `newt-eda` toolchain (GCC 16.1.0) already exceeds
the GCC ≥ 13 / binutils ≥ 2.40 floor that keeping `Zknh` open required.

---

## Phase ordering

```
Phase 0  ──►  Phase 1 (newt-eda image) ─┐
             Phase 2 (Verilator flow)  ─┴─►  Phase 3 (fast CI) ──► Phase 4 (synth CI) ──► Phase 5+6 (P&R + Azure)
                                                                └►  Phase 7 (coprocessor RTL)  ✅
                                                                └►  Phase 8 (svase→yosys-slang, exploratory, parallel)

Phase 5+6  ──►  Phase 9  ✅ (post-merge CI verification — gated on `ci-pnr-lane` landing)
Phase 10 (Actions version upgrade)  — independent maintenance, any time
Phase 12 (yosys fork retired -> upstream v0.69)  ✅  — unblocks Phase 8
Phase 11 (backend routability)      — design work; gates a detail-routed DEF, nothing else
Phase 13 (Cheshire 4a270af -> v0.3.1)  ✅  — dependency maintenance; synth drift ≤0.32%
Phase 17 (SoC default-activity power collapse) — finding; gates any SoC-level power delta
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
      required, no force-push/deletion. Required checks: `lint`, `sw` (Phase 3's real,
      gating jobs — see Phase 3 below; its three stub jobs are deliberately not required).
- [x] Add `docs/` (this file). CODEOWNERS dropped — pointless for a solo repo
      (recreate as `.github/CODEOWNERS` with `* @wortexx` if collaborators join).
- [x] **Naming:** `PROJ_NAME` / `RTL_NAME` stay `basilisk`. **Won't do (2026-10-05):** the
      rename is no longer optional, because `AGENTS.md` and `openspec/config.yaml` make it a hard
      constraint. Many scripts hardcode the name (`basilisk.sdc`, checkpoint/report paths), and
      the thesis gains nothing from a rename.
- [x] **Dependency strategy** for modified IP: settled by
      [ADR-0002](adr/adr-0002-bender-pinned-forks-not-patches.md) (accepted 2026-09-13, a hard
      constraint in `AGENTS.md`). Dependency changes go through Bender-pinned forks, not pickle
      patches.
  - **Cheshire is forked:** `wortexx/cheshire`, branch `newt/v0.3.1`, pinned by
    `rev: v0.3.1-newt.2`. `newt.1` builds the address maps without the constant functions that
    Xcelium rejects (Phase 14). `newt.2` exposes core 0's CV-X-IF port and adds the
    `Cva6CvxifEn` config field (Phase 7).
  - **A CVA6 fork was never needed:** CV-X-IF is enabled through Cheshire's config field, the ISE
    needs no CVA6 RTL change ([ADR-0003](adr/adr-0003-sha3-via-cvxif.md)), and `Zknh` was
    rejected. CVA6 still comes in through Cheshire at `pulp-v1.0.0`.
  - **Still open:** the inherited `target/ihp13/pickle/patches/` predate ADR-0002 and remain.
    `wt_axi_adapter2.patch` (CVA6) is about to get a second consumer, the Verilator lane
    (`verilator-sim-flow` task 3.0). A fix shared by two lanes is the case ADR-0002 says belongs
    in a fork. That would mean a direct `cva6` override in `Bender.yml`, so it waits until the
    patch actually causes trouble. Phase 16's odd-exit-code fix is already planned as a
    Cheshire fork patch, which would be the next tag (`newt.3`).

## Phase 1 — `newt-eda` tooling image  ✅ done (2026-08-30)

Derive from the existing `docker/` multi-stage layout; do not rewrite from scratch.
Full planning + implementation record: `openspec/changes/newt-eda-tooling-image/`
(archived once synced; see its `tasks.md` for the blow-by-blow of every bug found and fixed).

- [x] `DOCKER_BASE_IMG`: `almalinux:8.9` → `ubuntu:24.04` in all of
      `docker/{pickle,yosys,openroad,riscv64}/Dockerfile`; port `packages.txt` yum → apt.
- [x] **OpenROAD**: bumped `OR_COMMIT` to `2c56926` (latest master as of 2026-08-29 —
      OpenROAD doesn't cut regular tagged releases; last one was `v0.9.0-beta`, 2020).
      Dependency build switched to OpenROAD's own `etc/DependencyInstaller.sh -all`,
      replacing the hand-rolled boost/eigen/lemon/spdlog/swig chain.
- [x] **riscv64 toolchain**: bumped to release `2026.08.27` (GCC 16.1.0, well past the
      ≥13 bar; `Zknh` compiles).
- [x] **Kept pinned** *(at the time; yosys has since moved to upstream v0.69 — see Phase 12)*: yosys fork `3ce5059`, morty `v0.9.0`, svase `f5f5290`, sv2v `v0.0.11`,
      bender `v0.27.4`.
- [x] **Added**: Verilator `v5.050`, Verible `v0.0-4148-g1ea007ec` (static release binary).
- [x] Published to **GHCR**: `ghcr.io/wortexx/newt-eda:2026-08-29-8d13fe0` + moving `:dev`,
      publicly pullable (confirmed by an anonymous `docker pull`, no visibility fix needed).
- [x] Workflow: `.github/workflows/docker-image.yml` rebuilds + publishes on `docker/**`
      changes (PRs build-verify only; `main` pushes publish).
- [x] **Adoption gate: PASS.** `make synth-all` on unmodified Basilisk vs. the 2024 baseline:
      completed in ~2h28m (baseline ~2h27m) on a 32GB-RAM/55GB-swap box, peak 29.6GB, no OOM;
      yosys `CHECK` 0 problems both sides; cell count 722,285→714,166 (−1.1%), chip area
      17,219,125.78→17,156,844.69 (−0.36%), DFF count 89,261→89,258 (−3) — smaller, not
      bigger. Root-caused as far as worth chasing: bootrom cell redistribution traces to the
      *intentional* GCC 13→16 bump; a residual ~830-module textual divergence in the pickled
      RTL remains only partially explained (bender-version schema differences ruled out as the
      cause; see Risks). Small, benign-direction, explained-enough per this proposal's own bar.
      2024 image (`phsauter/pulp-iguana:dev`) kept reachable via `make -C docker pull-legacy`.
- [x] Flip `docker-compose.yml`/`use-docker.sh` to `newt-eda:dev` as the default dev image.
      Done same-day (2026-08-30, commit `2ba8bdf`, PR #7, task 5.2 of the archived
      `newt-eda-tooling-image` change) — this list previously said "not yet done," stale.
- [x] ~~Expect 2–3 days adapting `chip.tcl` to newer OpenROAD command APIs~~ — **deliberately
      skipped (user decision, 2026-10-05)**, not attempted. Phase 5's staged flow
      (`scripts/pnr/*.tcl` + `run_pnr.sh`) already carries the needed fixes for every stage
      that actually runs in CI or produced any thesis PPA number — e.g. `drt.tcl` drops
      `detailed_route`'s `-bottom_routing_layer`/`-top_routing_layer` (a hard error on
      OpenROAD `2c56926`, DRT-0509/0510) in favour of `set_routing_layers`, which `chip.tcl`
      still never got. `chip.tcl` itself was left unfixed and still hard-errors at that stage.
      Its only remaining role is interactive local GUI debugging (`openroad -gui`), which
      nothing currently needs — the `eda-tooling-image` spec carries no requirement on it.
      Revisit only if GUI-based backend debugging is needed again.
- [x] **Found and fixed along the way**: the image was missing `gawk`/`unzip`
      (`yosys.mk`/`openroad.mk` pipe logs through `gawk '{ print strftime(...) }'`; OpenROAD's
      `checkpoint.tcl` uses `unzip`) — neither is an EDA tool the original smoke test checked
      for. Fixed in `docker/all/packages.txt`; smoke test extended so a missing flow-support
      utility like this gets caught by CI next time.

## Phase 2 — Verilator simulation flow  *(critical path)*  🟡 in progress

Questa stays as a local-only waveform-debug target. Full record:
`openspec/changes/verilator-sim-flow/` (not yet archived — green light not reached).

- [x] Add `bender script verilator` + a Verilator build to `iguana.mk`
      (mirror `ig-sim-rtl`; reuse `BENDER_SYNTH_TARGETS`, not `BENDER_SIM_TARGETS` — see the
      change's task 1.1 for why `-t simulation` was rejected). Crib from Cheshire / CVA6
      upstream Verilator support (a never-merged 2023 Cheshire branch cribbed for JTAG/DM
      register-map details, not code — see design.md D2/D3).
      DUT is `iguana_soc` (`-D NO_HYPERBUS`), not the chip top or a hand-duplicated
      `cheshire_soc` wrapper — full 798-module SoC verilates clean (`verilator --cc`, one
      scoped `.vlt` waiver, no IP fork needed).
- [x] Port `SIM_PRE_COMPILE` (`BOOTMODE` / `PRELMODE` / `BINARY`) to Verilator plusargs
      (`+BINARY=`, `+BOOTMODE=`, `+PRELMODE=`, `+TIMEOUT_CYCLES=`); this lane only supports
      `BOOTMODE=0`/`PRELMODE=0` (SPM boot, JTAG preload) — other values are rejected with a
      clear error rather than silently ignored.
- [ ] **Green light:** `sw/tests/helloworld.spm.elf` boots and prints under Verilator, exit 0.
      **Blocked, deferred (2026-09-01).** A from-scratch JTAG-DTM + RISC-V Debug Module driver
      was built (bit-banged TAP, DMI, SBA — no fesvr/DPI dependency) and validated at the TAP
      level (IDCODE readback correct). The DMI protocol reports success throughout ELF preload
      and the abstract command that sets `dpc`, but `DMSTATUS`'s hart-status bits (and
      separately, SBA memory reads) return a value that never changes across repeated reads,
      including when no halt is ever requested — not yet root-caused despite comparison against
      two reference drivers (`croc`'s `riscv_dbg_simple` and the canonical `riscv-dbg`
      `jtag_test::riscv_dbg`). Root-causing this for real likely needs a licensed-simulator
      cross-check (Questa or Xcelium) or a waveform trace — not worth blocking Phase 3 setup on,
      so it's parked as follow-up work rather than a Phase 2 gate; see the change's tasks.md
      (3.1) and design.md's addendum for the full investigation log. Phase 3's `sim-soc` job is
      scaffolded against this and gated/skipped until it lands.
      **Cross-checked 2026-09-28 (Phase 14).** On the same DUT under Xcelium, the reference driver
      halts and resumes the hart normally: `DMSTATUS` goes `0xc0c82` → `0xc0382` → `0xf0c82`.
      Every real `DMSTATUS` on this DM has low byte `0x82`, so the frozen `0x00000011` read here
      cannot come from the RTL. The bug is in this lane's C++ DMI read path. The Xcelium VCD is the
      reference trace for fixing it.
- [ ] Coprocessor **unit testbench** (Verilator or cocotb) driving the CV-X-IF / instruction
      interface directly with NIST KAT vectors. **Descoped from this phase** — moved to
      Phase 7 (depends on the still-open CV-X-IF-vs-`Zknh` decision and coprocessor RTL that
      doesn't exist yet); this phase delivers the simulator infrastructure it will run on.
- [ ] Fallback if full-SoC Verilator stalls (hyperbus / DRAM models are the usual snag):
      ship the unit TB first; do full-SoC sim in the synth lane later.
      Turned out unnecessary for verilation itself (full SoC verilates fine without
      hyperbus/DRAM, which this DUT ties off via `NO_HYPERBUS`); the *simulation* still
      stalls, but on the DM protocol issue above, not on verilating the SoC.

## Phase 3 — CI fast lane (GitHub-hosted, every PR + push)

Container `newt-eda`; runner `ubuntu-latest` (or an 8-core larger runner if sim is slow).

| Job | What | ~time |
| --- | --- | --- |
| `lint` | `bender sources` (was listed as `bender check` here originally — that command doesn't exist in any bender version, found via a real CI failure, see `ci-fast-lane` tasks.md 2.1); `verible-verilog-lint` + `verilator --lint-only` on changed RTL | ~2 min |
| `sw` | build test binaries incl. SHA KAT programs (riscv64 gcc) | ~3 min |
| `sim-unit` | coprocessor TB — full NIST KAT set | 5–15 min |
| `sim-soc` | Verilator: Cheshire boot + one KAT through the new instructions | 15–40 min |
| `synth-coproc` | yosys synth of the coprocessor module only → area + Fmax; fail on regression vs a checked-in budget file | 5–10 min |

- [x] `.github/workflows/ci.yml`: all five jobs above exist and run on every push/PR.
      `lint` and `sw` are real and gating (wired into `main`'s required status checks —
      see Phase 0 above). Full planning record: `openspec/changes/ci-fast-lane/`.
- [x] `sim-unit` and `synth-coproc` **graduated from stubs to real, gating jobs** once the
      Keccak coprocessor RTL landed under `hw/coproc/` (`sha3-cvxif-coprocessor` tasks 2.6/2.7;
      Phase 7). Both are required status checks on `main` (`contexts: ['lint', 'sw',
      'sim-unit', 'synth-coproc']`). This corrects the line above, which until now still said
      both were stubs blocked on "no Phase 7 coprocessor RTL yet" — stale once Phase 7 closed.
- [ ] `sim-soc` (Verilator full-SoC boot) is **still an intentionally scaffolded stub**, and
      correctly so: it is blocked on Phase 2's JTAG-DM bug (frozen `DMSTATUS`/SBA reads in the
      Verilator C++ DMI read path — not an RTL bug, per the 2026-09-28 Xcelium cross-check), not
      on missing RTL. It runs its real precondition check every time and reports that blocker,
      but always exits 0 and is not required until a dedicated follow-up graduates it — never
      automatically just because the blocker clears. No work has landed on the Verilator side of
      that bug since the cross-check; `openspec/changes/verilator-sim-flow/` is still 10/14
      tasks, all four open ones (2.5, 3.1–3.3) downstream of this same fix.

## Phase 4 — CI synth lane  ✅ done (2026-09-02)

Triggers: nightly + `workflow_dispatch` + label `full-synth`. Full planning + implementation
record: `openspec/changes/ci-synth-lane/` (not yet archived).

- [x] `make ig-hw-all && make pickle-all && make synth-all` → upload netlist + reports.
      `.github/workflows/synth.yml`. Verified end-to-end across four real runs (~2.5h each);
      flow, artifact uploads, and metrics summary all confirmed working on the actual
      self-hosted VM.
- [x] Post summary: cell count, area, DFF count, WNS vs baseline.
      `target/ihp13/yosys/scripts/synth_metrics.py` + `target/ihp13/yosys/synth-baseline.json`
      (seeded from the Phase 1 adoption-gate numbers). Cell count, chip area, and DFF count
      all confirmed matching baseline exactly (genuine near-zero drift) on real hardware.
      **WNS does not populate** — `basilisk.sdc`'s `*ddr_rcv_clk_o*` cell-pattern doesn't match
      this netlist (pre-existing content bug, not this change's scope to fix); the lane
      degrades gracefully (WNS shows "unavailable", job still exits 0) rather than failing.
      Tracked as deferred follow-up — see the change's design.md Risks table.
- [x] **Superseded during implementation:** the plan's "GitHub large runner first" assumption
      turned out non-viable, not just unproven — GitHub's hosted larger-runners feature
      requires a Team/Enterprise **organization** plan, unavailable to a personal-account repo
      at any tier (confirmed via `gh api`, not merely untried). Went straight to pulling
      Phase 5/6's self-hosted Azure VM forward (see Phase 5 below) rather than attempting the
      large-runner path first.
- [x] **Found and fixed along the way** (all in `.github/workflows/synth.yml` /
      `synth_metrics.py`, none in the flow itself): `synth_metrics.py` was double-counting
      cells/DFFs and mis-parsing chip area on this hierarchical design (yosys `stat` prints a
      per-submodule block before its real top-level rollup); the standalone `run-sta`
      invocation was missing `RTL_NAME=basilisk` and `PICKLE_OUT=../pickle/out` (both only set
      via the full `iguana.mk`/`pickle.mk` chain, which this standalone `make -f yosys.mk` call
      doesn't go through); and `basilisk.sdc`'s internal `source src/basilisk_instances.sdc`
      needed a CI-only symlink to resolve given `opensta_timings.tcl`'s own cwd requirement.
      Full root-cause/fix/verification detail in the change's `tasks.md` (task 3.3).

## Phase 5 — CI P&R lane (self-hosted Azure agent)  ✅ built (2026-09-13)

Delivered by `openspec/changes/ci-pnr-lane/` — all 18 tasks closed. **Post-merge verification
continues in Phase 9**, and a detail-routed DEF is blocked on Phase 11; neither is a gap in
the lane itself.

**History.** Partially pulled forward (2026-09-02) as part of Phase 4 — see
`openspec/changes/ci-synth-lane/` design.md D1/D1a/D1b. The VM (`newt-synth-runner`,
`newt-synth-lane-rg`, `swedencentral`, `Standard_E16ds_v5`) and its `self-hosted-synth` runner
came from there; VM lifecycle was manual, with a 10:00 UTC auto-shutdown backstop that this
phase superseded — deallocation is now handled by this phase's own guarded `stop` job and the
hourly `vm-watchdog.yml`, both observed working for real during Phase 9
(`post-merge-ci-verification` tasks 2.1–2.3/3.3 for `stop`, task 4.1 for the watchdog's
idle-deallocate), and the fixed auto-shutdown schedule was deleted 2026-09-16 (task 5.1) once
that observation confirmed there would never be a window with no backstop.

**Checkpoint loss, 2026-09-15 (fixed).** The lane's first post-merge full run
(34783899813, Phase 9's "Run A", ~26h and ~$32) finished `pnr` with `grt ok` and then
uploaded nothing: the nightly synth run 34820756433 took the shared runner 2s after `pnr`
released it, and its `actions/checkout` `git clean -ffdx` wiped the untracked
`target/ihp13/openroad/save/` 6s later — 2.5h before `upload-checkpoints` got the runner and
found an empty directory, which it reported as "nothing to upload (pnr job may have failed
before floorplan)" and exited 0. The two lanes share one runner *and one workspace*, and
neither `pnr.yml`'s `concurrency: group: pnr` (which serializes `pnr.yml` runs against each
other) nor the `stop` coexistence guard (which only decides whether to power the VM off)
covered the gap between two jobs of the same run. Fixed by
`openspec/changes/pnr-checkpoints-outside-workspace/`: the `pnr` job now moves its checkpoints
to `/home/newt/pnr-export/<run_id>` before it ends — the same outside-the-workspace pattern
`restore-checkpoints` already used inbound — and `upload-checkpoints` reads only from there
and fails loudly instead of quietly when a successful flow leaves it nothing.

- [x] `start` job (GH-hosted, OIDC): `az vm start`, idempotent.
- [x] `pnr` job (`runs-on: [self-hosted, self-hosted-synth]` — *not* the `newt` label this
      plan guessed; `container: ghcr.io/wortexx/newt-eda:dev`, `timeout-minutes: 2880`).
      Runs the staged flow driver `target/ihp13/openroad/run_pnr.sh` over
      `scripts/pnr/*.tcl` — one `openroad -exit` process per stage, each loading the previous
      stage's checkpoint. (This plan's "reference implementation
      `scripts/resume_no_repair_timing.tcl`" never existed to build on: it was lost with
      `backend-run/` before the work started.) Stock `chip.tcl` is untouched, for local GUI
      use only. `remove_buffers` is wrapped in one retry — **verified by deliberate fault
      injection**, since it never actually crashed in any real run.
- [x] `stop` job (`if: always()`): a **guarded** deallocate — it queries the runner's busy
      flag and queued runs first, and skips with a log line rather than cutting off a
      concurrent synth run. Deliberately **without** `--no-wait`, against this plan's
      original sketch: a deallocation failure is a cost leak and must fail loudly, which
      needs the command to block on its result.
- [x] Artifacts: reports and logs → GitHub artifacts (30-day retention); checkpoints → Azure
      Blob with a 30-day lifecycle rule. **The DEF is published conditionally**, not on every
      green run — detailed routing is best-effort, so a run can legitimately exit 0 without
      one, and the step summary says which stage prevented it. See Phase 11.
- [x] Beyond the original plan, because bring-up demanded it: a netlist cache on the VM's OS
      disk (`actions/cache` is unusable here — per-ref scoping means tag-triggered runs can
      never read each other's caches); checkpoint **resume** from Blob with a netlist-identity
      guard; `PNR_STOP_AFTER`/`PNR_RESUME_EXCLUDE` to re-run one stage in minutes; and VM
      hardening after unattended-upgrades restarted the runner mid-job and killed a 30-hour
      run (see `ci-pnr-lane` design D11/D12).

**Repair bounding, as built.** The plan called for `repair_timing` "skipped or bounded"
(`-repair_tns 20 -max_buffer_percent 15`). Bounding proved insufficient — `grt_repair` chains
three route/repair phases and still hit a 16h ceiling — so it is currently **skipped
outright**. Consequence worth carrying into any PPA work: with post-route repair off, reported
WNS is far worse than this document's ≈ −2.5 ns assumption (−14.76 at `grt` in bringup-7).

**Measured cost**: 10 bring-up runs, 158.84 VM-hours, ≈ $193 at $1.216/h. The last two runs
cost ~$15 each versus $30–38 before the threading, antenna-skip, cache and resume work landed.

## Phase 6 — Azure infrastructure as code  ✅ done (2026-09-13)

Built as **Bicep**, in `infra/azure/` — see [`infra/azure/README.md`](../infra/azure/README.md),
which is now the authoritative description of the CI's Azure footprint. The
archived ci-pnr-lane runbook records how these resources were originally built
by hand and is kept only as history.

- [x] **Bicep** (`infra/azure/main.bicep`, resource-group scoped, deployed
      incrementally behind an `az deployment group what-if` preview): the VM with its
      NIC, VNet, public IP and NSG; the `newt-ci-identity` user-assigned identity and
      its **OIDC federated credential** (no stored secrets); both minimally-scoped role
      assignments; the checkpoint storage account, container and 30-day lifecycle rule;
      a Key Vault; and a budget alert. The existing hand-built resources were adopted in
      place — nothing was recreated and the OS disk (runner registration, Docker cache,
      synth cache) was never touched.
- [x] Runner registration: **PAT in Key Vault**, read by the VM's own system-assigned
      identity over IMDS and exchanged for a short-lived registration token.
      `newt-ci-identity` deliberately gets no vault access. A GitHub App would be
      cleaner but needs private-key handling and JWT minting for a solo repo.
- [x] **Reproducible runner host** without a golden image: `infra/azure/cloud-init.yaml`
      plus the idempotent `infra/azure/provision-runner.sh` bring a fresh VM to the
      state the lanes need (Docker, az CLI, Actions runner as a service,
      `apt-daily-upgrade.timer` disabled, needrestart override). The same script
      converges the existing VM through Run Command.
- [x] **Budget alert**: resource-group monthly budget, e-mail at 50/80/100 % of actual
      spend. A notification, not an enforcement — `vm-watchdog.yml` (Phase 5) is what
      actually bounds spend.
- [x] Infra validation in CI: `.github/workflows/infra.yml` builds and lints the
      templates on every PR touching `infra/**`, holding no Azure credentials.
- [ ] **Deferred — golden VM image (Packer)**: it adds a tool, an image store and a
      rebuild workflow, so it gets its own change rather than riding along here. The
      provisioning script is the stepping stone: a Packer template would call the same
      file. Cold-start pull cost stays until then.
- [ ] **Deferred — spot VM / second VM for the synth lane**: the single shared VM stays
      on-demand. P&R cannot use spot (`detailed_route` does not checkpoint mid-run, so an
      eviction loses the phase), and splitting the synth lane onto its own spot VM buys
      little while one runner serializes both lanes acceptably.
- Auto-deallocate on job end and a `concurrency` group of 1 were delivered in Phase 5,
  not here.

**Drift and the (former) one undeclared resource.** Incremental deployments never delete, so a
hand-made resource simply persists; `infra/azure/README.md` documents the
`az resource list` drift check. One live resource was deliberately left undeclared for a
time: the DevTestLab schedule `shutdown-computevm-newt-synth-runner`. Phase 9 deleted it
2026-09-16 (`post-merge-ci-verification` task 5.1), once `vm-watchdog.yml`'s idle-deallocate
had been observed working for real (task 4.1) — the resource group's nine live resources now
map to `main.bicep` declarations exactly, with no exception left.

**Follow-ups surfaced during implementation, not acted on:**

- [ ] `provision-runner.sh` overwrites a mismatched file (e.g. the needrestart
      override) rather than diffing it, so a convergence run cannot report *what*
      drifted — only that it did, after the fact, with the evidence already gone.
      A `--check` mode that reports a diff and exits non-zero without writing
      would make "converge the existing VM" safe to run exploratorily. New scope;
      wants its own change rather than riding along here.
- [ ] `needrestart -r l` was never re-verified on the live host after task 3.4
      rewrote its override file — the rewrite happened right before the VM was
      deallocated and the check's output never came back. Low risk (the file is
      byte-identical to the form the ci-pnr-lane runbook verified parses), but
      not independently confirmed on this host. Check next time the VM is up.
- **Shared-workspace collision between the P&R and synth lanes — fixed, not open.** Raised
  as a follow-up by `post-merge-ci-verification` task 2.1 after run 34783899813 lost its
  checkpoints to a sibling workflow's checkout (see Phase 5's History above). Addressed by
  `openspec/changes/pnr-checkpoints-outside-workspace/` rather than by serializing the lanes
  by hand, so re-enabling the nightly synth schedule no longer has to wait for the P&R lane
  to be idle. Recorded here because Phase 9's task 6.4 expects this list to carry it.
- **`github-runner-pat` expires 2026-12-13** — 90 days from creation, not the
  one-year cadence this plan originally assumed. Rotation is quarterly until a
  longer-lived token is deliberately issued; the vault secret's own `expires`
  attribute is the source of truth, `infra/azure/README.md` has the rotation
  steps.

## Phase 7 — Coprocessor scaffolding  ✅ done (2026-10-05)

Executed as `openspec/changes/archive/2026-10-05-sha3-cvxif-coprocessor/`; its `tasks.md` is the
detailed checklist — all 9 task groups (1–9), every item, closed. Both arms (CV-X-IF ISE and the
MMIO comparison accelerator) are built, tested, measured for PPA, and written up.

- [x] Config flip, **not** through `CVA6ConfigCvxifEn=1`: that package constant never reaches the
      core (Phase 15). Instead, Cheshire fork field `Cva6CvxifEn = 1` is set in `hw/iguana_pkg.sv`
      (change task 1.3; verified by elaboration).
- [x] Un-tie Cheshire `cvxif_*` port (fork `v0.3.1-newt.2`, `7b53138`; change task 1.1).
- [x] Decision from `custom-isa-extension.md`: mechanism 1 (CV-X-IF), hash SHA-3. See the
      "ISA integration" section above.
- [x] `hw/coproc/keccak_round.sv` / `keccak_pkg.sv` (shared θρπχι round + constants), `keccak_cvxif.sv`
      (the five-instruction ISE: `kclr`/`kxor`/`krd`/`shatr`/`kperm` on `custom-1`, one in-flight
      instruction plus an issue queue — design D3, revised) and `keccak_mmio.sv` (the MMIO comparison
      arm behind `axi_to_detailed_mem`, design D6), all added to `Bender.yml` (change tasks 2.1, 2.3,
      6.1). `RoundsPerCycle` swept at {1,2,3,4,6}; **R = 6** selected for the SoC (task 5.1).
- [x] Unit testbenches: Verilator block-level TBs for `keccak_round`, `keccak_cvxif` (every `R`,
      CV-X-IF scenarios incl. out-of-range index, illegal `rd≠x0`, save/restore) and `keccak_mmio`
      (AXI boundary, SLVERR, busy-hold, burst absorb) — all passing, picked up by the real `sim-unit`
      / `synth-coproc` CI jobs (change tasks 2.2, 2.4, 6.2, 2.6; graduated from stubs, now required
      checks per task 2.7).
- [x] `sw/tests/sha3_kat_*.c` — 40 NIST CAVP SHA-3 KAT vectors (`scripts/sha3_vectors.py`) run on the
      Xcelium lane against both ISE back-ends, both MMIO modes (CPU and iDMA), and three vendored
      software baselines, plus directed illegal-`rd` and IRQ-hazard tests (change tasks 3.5, 3.6, 4.2,
      6.5, 3.7).
- [x] SoC integration (`i_keccak_cvxif` + `i_keccak_mmio` both instantiated, `AxiExtNumSlv=1` for the
      MMIO window), full synth-lane and P&R-lane runs with both arms present (change tasks 3.1–3.3,
      6.3–6.4, 5.3, 8.2, 5.4), and the final evaluation report `docs/results/sha3-evaluation.md`
      (change task 8.3) covering speedups vs. three baselines, the rounds-per-cycle sweep, block/SoC
      PPA, activity-annotated energy, and the measured ISE-vs-MMIO crossover (cache-regime dependent;
      change tasks 7.1–7.2).
- [x] Clean-checkout integration check (change task 9.1, 2026-10-05): fresh clone, full CI fast lane
      green, 11/11 Xcelium tests pass, `openspec validate --strict` passes.

**Known follow-up, not part of this change's scope:** the whole-SoC default-activity power report
with both arms present collapses to roughly half the pre-coprocessor reference, starting before any
placement — tracked separately as Phase 17 below. It does not affect the thesis energy figures, which
come from activity-annotated block power (change tasks 5.2, 5.5, 8.1), not SoC-level default activity.

## Phase 8 — Replace svase+sv2v with `yosys-slang`  *(exploratory, not blocking)*

> **Sequencing (2026-10-02, user decision):** this migration lands **after** the `sha3-cvxif-coprocessor` PPA measurements. That change measures on the current svase/sv2v frontend against the current baseline, so no frontend delta mixes into the coprocessor delta (its design D10).

> **Prerequisite met (2026-09-17).** This needed yosys ≥ 0.67, the first release with the slang
> frontend built in (the standalone plugin supports only 0.52–0.66). The toolchain is now on
> upstream v0.69 and the image asserts `read_slang` is available, so the prototype below can start.

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

## Phase 9 — Post-merge CI verification  ✅ done (2026-09-17)

Several P&R-lane acceptance items are **not** verifiable from a feature branch, for one
GitHub-side reason: a workflow's `schedule` and `workflow_dispatch` triggers are only
registered once the workflow file exists on the repository's **default branch**. Tag pushes
are exempt (any ref's push evaluates the workflows in that ref's tree), which is why the whole
bring-up ran off `pnr-bringup-*` tags. So these are deferred by sequencing, not by difficulty:

- [x] Real `workflow_dispatch` run of `pnr.yml` (the bring-up used tag pushes throughout —
      `gh workflow run pnr.yml` 404s pre-merge, and `pnr.yml` doesn't even appear in
      `gh workflow list`). Confirms the `resume_from_run` input path, which has never run.
      **Observed 2026-09-13 through 2026-09-16**: run 34783899813 (a fresh full run,
      `resume_from_run` empty — confirms the inputs are inert by default) reached `grt ok`;
      run 34938462965 re-established Blob checkpoints after the collision below; run
      35100509927 ("Run B") dispatched with `resume_from_run=34938462965
      resume_exclude=grt_repaired stop_after=grt_repair` and exercised the `resume_from_run`
      path for real — netlist-identity guard's matching path, checkpoints restored, the
      excluded stage re-run, stopped after `grt_repair`, `success` in ~12 min
      (`post-merge-ci-verification` tasks 2.1, 3.1–3.2).
- [x] `vm-watchdog.yml`'s hourly cron actually firing, and its OIDC login /
      power-state check succeeding unattended. **Observed (2026-09-13), during
      `azure-infra-as-code` task 2.4**: one manual `workflow_dispatch` plus two
      unprompted scheduled runs (11:20, 14:10, 17:59 UTC) all completed
      successfully via `Azure login (OIDC)` → `Check VM power state` →
      `Nothing to do`.
- [x] One observed correct **idle-deallocate** (the `Deallocate idle VM` step
      actually running). **Observed 2026-09-16T19:53:19Z, run 35143225494**: a slice
      dispatch's `stop` guard left the VM up for a queued synth run (`post-merge-ci-verification`
      task 3.3), that synth run completed, and this was the next hourly tick with nothing
      queued — `"VM is running and idle - deallocating."`, `Deallocate idle VM` `success`,
      confirmed by `az vm get-instance-view` → `PowerState/deallocated` (task 4.1).
- [x] **Only after** an observed correct idle-deallocate: delete the Azure fixed
      auto-shutdown (currently `status: Disabled` by hand, not removed — reconfirmed
      2026-09-13) and enable the weekly `pnr.yml` cron. Never leave a window with no
      cost backstop at all. **Done 2026-09-16**: auto-shutdown schedule deleted at
      2026-09-16T21:55:33Z, user-approved (`post-merge-ci-verification` task 5.1) — resource
      group drops to nine resources, all declared. The weekly cron needed no "enabling": it
      was already found `active` post-merge (task 5.2) — its first scheduled run is due
      2026-09-18 18:00 UTC.
- [x] Re-enable the `CI Synth Lane` schedule (`gh workflow enable`) — disabled during
      bring-up so its nightly runs stopped competing for the single runner. **Done
      2026-09-16** (`post-merge-ci-verification` task 5.3, done ahead of this checklist item as
      a side effect of unblocking task 3.3's timed dispatch): `gh api
      .../actions/workflows/synth.yml --jq .state` → `active`.
- [x] Coexistence guard under a **real** overlap: with a P&R run active, trigger a synth-lane
      dispatch so a run queues, and confirm `pnr.yml`'s `stop` job skips deallocation with a
      clear log line and the queued synth job then runs. Deferred here because it wants both
      lanes' schedules live, which is only true post-merge. (The other half of that check
      needs revisiting: this section originally said `main` had no branch protection, so no
      P&R job could be a required check — that changed before `azure-infra-as-code` started;
      `main` now requires `lint` and `sw` (confirmed live, 2026-09-13). Neither `pnr.yml` nor
      `synth.yml` is in that list, and neither has a `pull_request` trigger, so this coexistence
      guard is unaffected — but the stale claim is corrected here rather than left standing.)
      **Both orderings observed** (`post-merge-ci-verification` tasks 2.2/2.3, 3.3): run
      34820756433 (synth) queued behind Run A's `pnr` job and got the runner first, so `stop`
      found nothing active and deallocated directly; a second timed dispatch caught the other
      ordering deterministically — synth run 35106656087 was still `queued`/`active` when
      slice run 35105723732's `stop` guard evaluated, which logged
      `"Another job is running or queued on the shared runner - leaving the VM up."` and
      skipped `Deallocate VM`, and the queued synth run then executed to `success`.
- [x] Update `synth.yml`'s header comment and this document's Phase 5 section to the
      post-watchdog reality: VM deallocated by default, started by `pnr.yml`, watchdog
      cleans up, fixed auto-shutdown gone. **Done 2026-09-17** (`post-merge-ci-verification`
      task 6.1 and this section's own History paragraph above). `synth.yml`'s header still
      carries one open item beyond this bullet's original scope: the nightly 02:30 UTC
      cron's actual behaviour against a deallocated-by-default VM needs a multi-night
      observation (task 5.4) not yet complete as of this writing; the header notes exactly
      that and will be filled in once observed.

## Phase 10 — GitHub Actions version upgrade  ✅ done (2026-09-17)

Every action pinned across `ci.yml` / `synth.yml` / `pnr.yml` / `docker-image.yml` declared
the **Node 20** runtime, which GitHub deprecated. Runners have defaulted to Node 24 since
2026-06-16 and were already forcing these actions onto it (that was the warning in every run
log); Node 20 is removed entirely on **2026-09-23**. Nothing in this repo broke on that date —
the forcing is what we already ran on, and we never set the
`ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION` opt-out — but every action here was several majors
behind. Resolved as `upgrade-github-actions`; see that change's `design.md` for the full
rationale. As bumped:

| action | was | now | uses |
| --- | --- | --- | --- |
| `actions/checkout` | v4 (x9) | v7.0.1 | node20 → node24 |
| `actions/upload-artifact` | v4 (x4) | v7.0.1 | node20 → node24 |
| `azure/login` | v2 (x5) | v3.1.0, SHA-pinned | node20 → node24 |
| `docker/build-push-action` | v6 (x6) | v7.4.0, SHA-pinned | node20 → node24 |
| `docker/setup-buildx-action` | v3 | v4.4.1, SHA-pinned | node20 → node24 |
| `docker/login-action` | v3 | v4.6.0, SHA-pinned | node20 → node24 |

Actual approach diverged from the plan above, deliberately:

- Went straight to each action's latest major in one commit rather than stepping through
  intermediate majors one at a time. Every deprecation the intermediate majors carried was
  checked against the actual call sites in this repo and none applied (no
  `DOCKER_BUILD_NO_SUMMARY`/`DOCKER_BUILD_EXPORT_RETENTION_DAYS` usage, no deprecated
  `setup-buildx-action` inputs, no `pull_request_target`/`workflow_run` trigger for
  `checkout` v7's fork-PR guard to matter against). Stepping through would have paid the
  same validation cost multiple times for zero risk reduction here.
- **New convention:** every third-party action (`docker/*`, `azure/*` — anything outside the
  `actions/` org) is now pinned to a full 40-character commit SHA with a trailing
  `# vX.Y.Z` comment, so a compromised or retagged upstream release can't silently change
  what runs on runners holding Azure OIDC and GHCR credentials. `actions/*` stays on major
  tags — GitHub controls both that namespace and the runner executing it. Keep this
  convention for any new action reference added to `.github/workflows/`.
- `azure/login` was **not** left for last — going straight to latest major and validating
  all six together in one PR made a staged rollout pointless; the hosted lanes gate the PR,
  and the self-hosted lane's `azure/login` sites (VM start/deallocate, checkpoint upload)
  are verified on the next scheduled `pnr.yml` run instead (still not folded into a
  pre-merge gate — a regression there is exactly the class of thing that only surfaces
  hours into a run, per the original note below).
- Added `.github/dependabot.yml` (`github-actions` ecosystem, weekly, grouped into one PR,
  no auto-merge) so this doesn't silently drift to three majors behind again.
- Not folded into `ci-pnr-lane`: a workflow regression there surfaces only *after* ~3h of
  synthesis, exactly how the `-f openroad.mk`, `PROJ_NAME` and `PNR_TIMEOUT_GRT` bugs were
  each found.

## Phase 11 — Backend routability  *(design work, not infra — the real P&R blocker)*

The P&R lane now runs end to end unattended, but **the design as placed and globally routed
cannot be detail-routed**. `pnr-bringup-10` got `detailed_route` to completion for the first
time: ~27 min of pin access, then **12h03m on iteration 0 alone**, finishing with
**22,419,919 violations**, and post-processing failed with `[ERROR DRT-0206]
checkConnectivity error` (a reset net left unconnected). The iteration budget was never the
constraint — iteration 1 was never reached — so no `drt` tuning fixes this.

The cause is upstream and already visible in `grt`'s own final congestion report: demand at
**101.17% of total routing capacity, Metal3 at 115.27%**, accepted only because
`global_route` runs with `-allow_congestion`. Global routing hands detailed routing a
solution that does not physically fit.

**2026-09-18 finding: `cts` now fails too, not just `drt`.** The first real weekly-cron run
since Phase 12's yosys v0.69 upgrade (run `35390510737`, `post-merge-ci-verification` task
5.2) timed out in `cts` (its 4h default, exit 124) after `floorplan`/`pre_place`/`gpl`/`dpl`
all passed — the first `cts` failure in this project's history; every prior real run reached
`cts ok`. Not yet investigated: whether this is congestion-driven like the `drt` blocker below
(plausible, since v0.69's netlist is ~3% larger — Phase 12) or an unrelated regression.
Whoever picks this phase up should start by checking `cts.tcl`'s report for
congestion/setup-violation counts against the pre-upgrade baseline before assuming it shares
`drt`'s root cause. Recorded, not investigated, per the user's decision when this surfaced.

**2026-10-02 diagnosis: the design now overflows the `gpl` density target.** Investigated from
the `pnr-reports` artifacts of runs `34938462965` (09-15, `7dfc599`, pre-upgrade, reached `grt`),
`35390510737` (09-19, `cts` timeout) and `36188933699` (09-26, `599d837`, `dpl` timeout at its
2h limit). The two failed runs start `dpl` from an identical state (same netlist); one squeezed
through in 1h45 and the other did not, so the lane is on a knife edge. Not a `cts`-specific
regression: both timeouts are the **negotiation legalizer** (`DPL-1102`) grinding through
overlaps, in `dpl` and again inside `cts` after clock buffering.

| | 09-15 (ok) | 09-19 / 09-26 (failed) |
|---|---:|---:|
| movable area before `gpl` (`GPL-0036`) | 9.89 mm² | 10.42 mm² (+5.4 %) |
| utilization entering `dpl` (`DPL-0009`) | 62.9 % | **66.1 %** |
| illegal cells at legalizer iteration 0 | 82,811 | 203,229 (2.5×) |
| `dpl` runtime (limit 2h) | 1h28 | 1h45 / >2h |
| legalization inside `cts` | 1h19 | 3h09 (then the 4h `cts` limit) |
| HPWL after `cts` legalization | 166 M µm | 215 M µm (+29 %) |

~~Cause: the design overflows `-density 0.65`.~~ **Corrected 2026-10-03 after run
`37037836332`.** That run placed at `-density 0.72` (`raise-gpl-density-target`, full flow,
`stop_after=cts`), and `dpl` timed out again, starting from *more* illegal cells (223,074). The
first diagnosis misread `gpl`: `-density` is only the *starting* target. Every run on record
goes the same way inside `gpl` pass 2:

1. Routability mode inflates the target (0.71 → 1.06 in run `37037836332`).
2. `gpl` reverts that inflation itself, to the least-congested iteration (`GPL-0055`).
3. The second timing-driven iteration then runs a real (non-virtual) `repair_design` while
   overflow is still ≈ 0.2. It adds 0.9–1.2 mm² of buffers (+5–7 %), and the target jumps.
4. Nesterov diverges, `gpl` reverts to a snapshot (`GPL-0999`), and it hands `dpl` an
   unconverged placement.

(The ~0.669 quoted before was only the first timing-driven adjustment.)

| | 34938462965 (09-15, ok) | 36188933699 (09-26, 0.65) | 37037836332 (0.72) |
|---|---:|---:|---:|
| target after pass 2's timing-driven repair (`GPL-0110`) | 0.895 | 0.993 | 1.043 |
| `repair_design` area in that iteration (`GPL-0107`) | +6.85 % | +4.79 % | +6.11 % |
| pass 2 reverted to overflow (`GPL-0999`) | 0.189 | 0.218 | 0.217 |
| final placement area (`GPL-1014`) | +29.5 % | +51.7 % | +59.4 % |
| `DPL-0009` utilization | 62.9 % | 66.1 % | 67.3 % |
| illegal cells at legalizer iteration 0 | 82,811 | 203,229 | 223,074 |
| illegal cells at iteration 570 | — | 26,386 | 34,939 |

The good run went through the same divergence; its jump was just smaller. A higher starting
density makes the jump bigger.

- [x] **Make `gpl` pass 2's timing-driven repair virtual, and raise the legalization timeouts**
      (`raise-gpl-density-target`, revised 2026-10-03). `-keep_resize_below_overflow 0`
      (`pnr_gpl_keep_resize`, `PNR_GPL_KEEP_RESIZE`): the timing-driven iterations still
      re-weight nets, but they insert no buffers into a half-spread placement. The real
      `repair_design`/`repair_timing` between the passes is unchanged. Density goes back to
      0.65. Timeouts as a safety net: `dpl` 2h → 4h, `cts` 4h → 8h. Changing a timeout does not
      change the result, so the run still shows whether the old limits would have held. Run it
      with `stop_after=grt`, because the change can move congestion into routing. Compare
      against run `34938462965`: `gpl` revert/convergence, illegal cells at iteration 0,
      `dpl`/`cts` runtimes, HPWL, `grt` congestion against 101.17 % demand / 115.27 % Metal3,
      and WNS. Success is reaching `grt`; the result becomes the pre-coprocessor reference for
      the SHA-3 change's task 5.4.
      **Done 2026-10-03: run `37108127061` (`dff4df0`, taped-out die) reached `grt ok`.**
      `gpl` pass 2 converged (no revert). Against run `34938462965`:
      - HPWL after `dpl`: 81.0 M vs 148.8 M µm; after `cts`: 124.7 M vs 166.3 M µm.
      - `grt` demand 83.57 % (was 101.17 %); Metal3 108.99 % (was 115.27 %).
      - WNS at `grt`: −8.36 ns (was −14.76 ns).
      - `DPL-0009` utilization 60.8 %, with 106,255 illegal cells at iteration 0.
      - Default-activity power: 1.82 W (was 1.46 W).
      - Runtimes: `gpl` 2 h 37 m, `dpl` 1 h 40 m, `cts` 6 h 58 m (over the old 4 h limit; the
        8 h one was needed), `grt` 3 h 10 m.
      **This run is the clean pre-coprocessor P&R reference** (the user's call, 2026-10-04: same
      netlist and same settings as `main` after the merge, so no re-run on `main`). P&R figures
      from before this change are not comparable with figures from after it.
- [ ] **Larger die, held in reserve** (`raise-gpl-density-target` D5, 2026-10-03). Input
      `die_scale` / `PNR_DIE_SCALE` (`pnr_die_scale`, default 1.0 = the taped-out die). 1.10
      gives a 6777 × 5950 µm die, core 31.2 mm² (+21 %), utilization entering `dpl` ~55 %.
      Not needed for the reference: run `37108127061` reached `grt` on the taped-out die with
      the virtual-repair fix alone (60.8 % utilization). Use it if the coprocessor's netlist
      (~3 points more) stops legalizing in time; its P&R figures are then for that floorplan.
- [x] ~~**Raise the `gpl` density target above real utilization**~~ — tried at 0.72 (run
      `37037836332`), made legalization worse; see the correction above.

Candidate levers, roughly cheapest first — none yet tried:

- [ ] **Relax our own layer adjustments.** `pnr_apply_routing_layers` removes 30% of M2/M3
      capacity (`set_global_routing_layer_adjustment Metal2-Metal3 0.30`) and 20% of
      TopMetal1 — and Metal3 is the worst-congested layer. This looks self-inflicted and is a
      one-line experiment.
- [ ] **Restore `grt` congestion iterations.** Stock `chip.tcl` uses 80; we cut to 14 purely
      to fit a timeout, with a comment explicitly accepting "a more-congested result for drt
      to deal with". Not a straight revert: iterations cost ~25 min each (80 ≈ 20–33h) and
      iteration 15 was separately observed entering an NDR-relaxation cascade that never
      terminated.
- [ ] **Lower `gpl` density** from `-density 0.65`, trading area for routability. *(Only the
      starting target; see the 2026-10-03 correction above for what actually sets the
      density `dpl` inherits.)*
- [ ] **Floorplan changes** — largest lift, last resort.
- [ ] **First, settle the framing question**: does the thesis's PPA comparison for the SHA
      extension actually need a *detail-routed* DEF, or do area/timing/power after CTS and
      global route suffice? The lane already produces the latter. If they do, this entire
      phase is optional measurement-quality work rather than a blocker, which matches the P&R
      lane's own design non-goal ("timing closure and DRC convergence are not goals — the
      lane measures, it doesn't fix").

Iteration here is now cheap: `PNR_RESUME_EXCLUDE` + `PNR_STOP_AFTER` plus the checkpoint
restore let a single stage re-run against real data in minutes rather than a full flow, and
the synth cache removes the ~3h resynthesis.

---

## Phase 12 — yosys fork retired, upstream v0.69  ✅ done (2026-09-17)

The flow ran a custom yosys fork: upstream 2024-04 plus three commits on `passes/techmap/abc.cc`,
4,483 commits behind. Both features it existed for had diverged — `-liberty_args` landed upstream in
v0.66, while the `{tmpdir}` script placeholder never will (PR #4343 closed, successor #4592 closed).
Separately, Phase 8 cannot start on a 0.40-era fork because the slang frontend is built in only from
v0.67. Change: `openspec/changes/upgrade-yosys-upstream`.

- [x] `docker/yosys/Dockerfile` → upstream **v0.69**, pinned by release tag, CMake build from the
      release tarball (which bundles the abc/slang/fmt submodules the auto-generated archives omit;
      note it has **no top-level directory**, so no `--strip-components`).
- [x] Smoke test asserts the pinned version, `abc -liberty_args`, and built-in `read_slang`.
- [x] **Composite image now assembled from stage digests, not the mutable `:ci` tag.** buildx does not
      re-resolve a tag whose resolution it has cached, so the composite had been able to consume a
      previous run's stage image. Latent since the workflow was written; only surfaced because this
      was the first change to a stage. Digests also stop concurrent PR runs clobbering each other.
- [x] Synth-lane metrics parse `stat -json`; v0.69's text `stat` no longer prints the
      `Number of cells:` lines the old parser scraped.
- [x] Removed the ABC BLIF round-trip that depended on the fork-only `{tmpdir}` substitution
      (upstream passes a user `-script` to ABC verbatim, so it arrived as a literal directory name).
- [x] **Dropped `abc -liberty_args "-S 20 -G 3"`** — it segfaults ABC on v0.69 whenever a user
      `-script` is also given, confirmed on native x86_64. See `design.md` D9 for the reproduction
      matrix and two ruled-out root causes.
- [x] **Adoption gate PASSED** (run 35275581702): `synth-all` in **110 min** vs ~148 min baseline
      (~25% faster — v0.69 runs ABC in parallel), yosys `CHECK` **0 problems**.

| metric | v0.69 | fork baseline | delta |
| --- | --- | --- | --- |
| cells | 735,953 | 714,166 | **+3.05%** |
| chip area (um²) | 17,774,827.51 | 17,156,844.69 | **+3.60%** |
| DFFs | 89,499 | 89,258 | +0.27% |

`synth-baseline.json` reseeded from this run. The +3% is **accepted deliberately** (see PPA note below).

**Known-bad, left in place:** the netlist-naming check added by this change greps the *yosys* netlist
for the flattened instance paths `macros.tcl` uses. Those exist only after *OpenROAD* flattens; in the
yosys netlist the ~25 `YOSYS_KEEP_HIER_INST` instances are real modules with local internal names, so
only 20 of 122 patterns can ever match. It failed the gate for a defect that was not there and is now
**advisory, never gating**. Fix it by restricting it to leaf globs (`*RM_IHP*`, `*i_delay_line*`,
`*_reg`) or by running it against the OpenROAD-flattened netlist.

### PPA improvement opportunities

The area is what it is today, not what it has to be. Roughly in order of expected payoff per unit of
effort:

1. **Recover the `-liberty_args` delay model (~3% area).** `-S 20 -G 3` made ABC derive its internal
   delay model from the liberty's slew/gain instead of a unit model, and dropping it is the most
   likely cause of the +3%. It is unusable on v0.69 only because of the crash in D9. Fixing that
   upstream — or finding the equivalent knob on the newer merged-SCL (`read_scl`) path, which may
   already carry this information — would plausibly return most of the delta. Best value here.
2. **Re-examine the ABC script itself.** `abc-speed-opt-new.script` is tuned for 2022-era ABC and
   still uses the "Lazy Man's Synthesis" record library (`rec_start3` on a 42 MB AIG). v0.69 bundles
   an ABC more than two years newer with passes the script never calls. Worth an A/B against a
   modern `&nf`-based flow before assuming the current script is optimal.
3. **Revisit `YOSYS_KEEP_HIER_INST`.** ~25 instances are kept hierarchical to make backend scripts
   able to find things by name. Every kept boundary blocks cross-module optimisation. Some entries
   exist for floorplanning convenience rather than necessity, and each one is a real area cost.
4. **Try `abc9`.** The flow uses the classic `abc` pass. `abc9` does better structural choices and
   timing-driven mapping on many designs. Needs care with the sequential path, and the flow already
   documents why FF handling is delicate here.
5. **Sequential optimisation / retiming.** `YOSYS_USE_ABC_SEQ` and `YOSYS_USE_ABC_RETIME` are both
   `0`. The script's own comments explain the clock-domain and init-value pitfalls, so this is the
   most invasive option — but it is also the only one on this list that can move the DFF count.

Worth noting for thesis framing: the ~25% synthesis speed-up from parallel ABC is itself a result,
and area and runtime are separate axes. None of the above is required for correctness; all of it is
optional PPA work that can follow the coprocessor.

## Phase 13 — Cheshire bumped to v0.3.1  ✅ done (2026-09-27, #48 + #49)

Cheshire was pinned to a raw commit, `4a270afccf27bed49779d11d88e4bbb69d335c8a` (2024-07-05), older than its first
tagged release. It now sits at release **v0.3.1** (`5c76406da7dd0399bb4179f739d1d768cfaf2d8f`, 2025-06-16).
Change: `openspec/changes/bump-cheshire-v0-3-1`. The CVA6 pin (`pulp-v1.0.0`) is unchanged.

- [x] **Lock policy.** Cheshire's dependency subtree is locked to the exact set Cheshire v0.3.1's own
      `Bender.lock` was released with, not the newest compatible patches. `bender update cheshire --recursive`
      (bender 0.32) floated 12 packages past it, and the image's bender 0.27.4 has no selective update. The lock
      is merged by hand and validated by `bender sources` under both versions. The existing `register_interface`
      (hyperbus `^0.3.2`) and `axi` (cva6 `^0.31`, serial_link/irq_router `^0.38`) requirement conflicts still
      need interactive resolution to the root pin on any future `bender update`.
- [x] **apb_uart held at 0.2.1.** Cheshire's 0.2.3 replaces the UART with an OBI UART from `obi_peripherals`.
      Its `obi_uart_tx` has a signal-bounded `for` loop that yosys's `read_verilog` rejects (*2nd expression of
      procedural for-loop is not constant*). `reg_uart_wrap`'s interface is identical, so 0.2.1 is a drop-in.
      Revisit when Phase 8 (`read_slang`) lands.
- [x] **Silent-drop fixes.** None of these errored before.
  - Keep-hierarchy selector `*/gen_dma.i_dma` → `*/gen_dma.i_idma`. Upstream renamed the instance; without the
    fix the DMA would have been flattened silently.
  - Obsolete after the bump, deleted: the `morty.sed` CVA6 ID-map rule (the text was rewritten upstream) and
    `protocol_e_axi_renaming.patch` (iDMA 0.6 rewrote the enum). Yosys accepts both constructs unpatched.
  - Already dead on `main`, deleted: `wt_axi_adapter.patch` (3/3 hunks failed, superseded by
    `wt_axi_adapter2`), the `sv2v.sed` `i < advance` rule (never matched), and the `*/gen_clic.i_clic`
    selector (CLIC is disabled).
  - The pickle stage applies patches with `-patch`, so a failing hunk never fails the build. The only way to
    find these is to sweep every rule against the stage it targets.
- [x] **Checked without a 2.5 h synth run.** The check replays `yosys_synthesis.tcl` up to
      `hierarchy -check -top iguana_chip` on the final pickle, in minutes. It passes, and all 24 keep-hierarchy
      selectors match at least 1 instance.
- [x] **Image.** Two additions, each now covered by a smoke-test check:
  - `flatdict`: iDMA 0.6's `gen_idma.py` imports it during `ig-hw-all`.
  - `gdisk` (`sgdisk`): iDMA 0.6's `idma.mk` sets `SHELL := /bin/bash`, so Cheshire's
    `sgdisk … &> /dev/null` no longer silently backgrounds a missing binary.
- [x] **CI lint.** The per-file `verilator --lint-only` step now elaborates from the linted file's own modules
      (`--top-module`, plus a wrapper top for package-only files). iDMA 0.6's `idma_generated.sv` mixes
      packages with ~50 `REG_BUS`-ported modules that otherwise all became lint roots.
- [x] **Software.** `ig-sw-all` builds with 10 test ELFs, and the bootrom is rebuilt from v0.3.1's sources
      (the split file keeps its size; its contents differ).
- [x] **Simulation, with Xcelium in place of Questa.** The `xcelium-sim-lane` VM runs used the post-bump RTL and passed `helloworld.spm`, `dma_2d` (iDMA 0.6) and `spm_uncached` (the now-live remap). `fixture_iguana`'s `vip_cheshire_soc` hookup was checked statically: no port changes, and one new parameter that defaults to 0. Verilator still fails to build on `main` too, for a pre-existing reason.
- [x] **Synth-lane metrics.** Run `36321657267`, against the PR image, passed with yosys `CHECK` at 0 problems. It is compared with the same-day `main` run `36306162671`, which reproduces `synth-baseline.json` exactly.

  | metric | main (4a270af) | v0.3.1 | delta |
  | --- | --- | --- | --- |
  | cells | 735,953 | 735,837 | −0.02% |
  | chip area (um²) | 17,774,827.51 | 17,776,378.83 | +0.01% |
  | DFFs | 89,499 | 89,209 | −0.32% |

  The drift is negligible, so the baseline is not reseeded; that is reserved for tool bumps. The fast lane's `sw` job needed the image packages on `:dev` before this could merge, so they landed first as #49.

**Behavioural changes that ride along**:
- The LLC's uncached-SPM remap (`AmSpmUnc`, `0x1400_0000`) was dead code at the old pin, because
  `a & ~M == b & ~M` parses as `a & (~M == b) & ~M`. It now works.
- The CVA6 debug `ExceptionAddress` is `0x810` (relative to `DmBaseAddress`), previously `0x808`.

**Follow-ups**:
- `iguana_pkg`'s "and activated CLIC" comment is false: `gen_cheshire_cfg()` never sets `Clic`. This matters
  for the CV-X-IF / interrupt work, and re-add the `gen_clic` keep-hierarchy selector if CLIC is enabled.
- Local-dev note: on Docker Desktop's virtiofs bind mount, symlinks the flow creates (`ig-hw-fma-opt`,
  `ig-hw-bootrom-split`) read back as `EPERM` inside the container. Build in a container-local volume, or on
  native Linux.

## Phase 14 — Xcelium simulation lane  ✅ done (2026-09-28, #51)

The first licensed simulator this project has actually run. Cadence Xcelium (`xrun` 24.03-s004) lives on a
restricted AWS VM (2 cores, 7 GB) with no git, Bender, Docker or
internet. Change: `openspec/changes/xcelium-sim-lane`. How to use it: `target/xcelium/README.md`.

- [x] **Bundle, not checkout.** `make ig-xrun-bundle` builds one ~1.4 MB archive: the Bender closure (570 files,
      bundle-relative paths under `deps/`), Cheshire's VIP and vendor models, the IHP13 behavioral macros, the DPI
      ELF loader, the test ELFs, `run.sh` and a provenance `MANIFEST`. A completeness check runs before archiving
      and again on the VM. On the VM, `./run.sh [tests]` compiles once, runs each ELF, and packs per-test
      `PASS`/`FAIL`/`TIMEOUT`/`ERROR` verdicts into one results archive.
- [x] **DUT parity.** It simulates `iguana_soc` with `NO_HYPERBUS`, the same unit as the Verilator lane, driven by
      Cheshire's `vip_cheshire_soc`. 539 of the Verilator lane's 542 file-list entries are shared; the rest are
      the Verilator harness itself.
- [x] **Green light.** `helloworld.spm` passes: JTAG halt → preload → resume, `Hello World!`, exit 0 at 2.19 ms
      simulated time. It takes ~47 s to compile and ~40 s to run. `dma_2d` and `spm_uncached` also pass.
      `axirt_*` and `clic_*` time out by design: `CheshireCfg` leaves AXI-RT and CLIC disabled (see Phase 13's
      CLIC follow-up).
- [x] **Cheshire now comes from a project fork.** Xcelium rejects `cheshire_soc.sv`'s `gen_axi_map()`/
      `gen_reg_map()` constant functions (`CFBADP`/`CFBADT`/`SVNSTP`). The code is legal SV, and no option
      relaxes it.
  - `wortexx/cheshire` branch `newt/v0.3.1` (cut from v0.3.1) builds the maps as constant-driven signals.
    It is tagged **`v0.3.1-newt.1`** (`465e9e8`) and pinned by `rev:`. Later patches continue as
    `v0.3.1-newt.<N>`, which is the fork line the CV-X-IF work will extend.
  - Synthesis (PR #51, run `36447894410`): yosys `CHECK` reports 0 problems, and pre-techmap statistics are
    identical in all 69 modules. Post-mapping, compared with v0.3.1: cells 735,557 (−0.04%), area
    17,771,117.07 µm² (−0.03%), DFFs 89,249 (+40). These come from ABC mapping sensitivity and land in untouched
    modules. Synthesis itself is deterministic run to run, so these are real but not logic changes.
  - `synth-baseline.json` is not reseeded.
- [x] **Found along the way.**
  - Bender lists two things `xrun` must not compile: duplicate module definitions that Questa silently
    overrides (`sram`, `configurable_delay`), and CVA6 headers that get compiled twice.
  - A copy to the VM silently dropped the hidden `.bender/` tree. That is why dependencies live under
    `deps/` in the bundle.
  - macOS bsdtar embeds xattrs that GNU tar warns about.
  - The fast-lane per-file Verilator lint cannot handle the testbench's hierarchical VIP calls, so it
    skips `target/xcelium/src/`.
- **Operational notes.**
  - SSH access is `ssh xcelium-vm` (key login for `sbidnyi`). Xcelium's environment comes from
    `~/.tcshrc`, so non-interactive commands need `tcsh -c`.
  - The VM has only a private `10.0.x` address. It became unreachable mid-session once, when the host's
    network route dropped.
  - Label-triggered synth runs (`full-synth`) wait for a deallocated runner VM. `synth.yml` has no
    start step, so start the VM (`az vm start`) or wait for `pnr.yml`.

---

## Phase 17 — SoC default-activity power collapses with the SHA-3 arms *(finding, 2026-10-04, not investigated)*

Found in P&R run `37162759719` (`sha3-cvxif-coprocessor` at `4c25003`, both `keccak_cvxif` and
`keccak_mmio` at R = 6, task 5.4). It is compared with the pre-coprocessor reference run
`37108127061` (Phase 11). Both runs used the same OpenROAD build (26Q3-1740-g2c56926971), the same
flow settings and the same SDC, and gave identical `check_setup` warnings. The SoC's
`report_power -corner tt` (default activity: the flow reads no SAIF or VCD) roughly halves:

| stage | reference: total / combinational | both arms: total / combinational |
|---|---:|---:|
| `pre_place` | 1.03 W / 0.237 W | 0.61 W / 0.006 W |
| `gpl2` | 1.08 W / 0.411 W | 0.49 W / 0.013 W |
| `grt` | 1.82 W / 0.470 W | 0.98 W / 0.019 W |

At `grt`, sequential switching drops from 34 mW to 1.6 mW, and macro power from 0.113 W to
0.029 W. The gap is already there at `pre_place`, right after the netlist is read and before
any placement. So it comes from the synthesized netlist as OpenSTA sees it, not from P&R.
Something in that netlist stops OpenSTA's default activity from propagating past the
flip-flops. Candidates, none checked:

- a reset or test net that becomes constant;
- a large combinational loop that OpenSTA breaks so that activity stops there;
- an interaction with CV-X-IF being enabled in CVA6.

Impact: SoC default-activity power is not a workload figure, and the `sha3-evaluation` spec
already rejects it. The thesis energy figures come from activity-annotated block power
(`docs/results/sha3-ppa.md`, tasks 5.2 and 5.5) and are not affected. But no SoC-level power
delta can be quoted from these runs, and the lane's power reports cannot be trusted until this
is understood. Timing and routing results are unaffected: WNS at `grt` is −8.23 ns, against
−8.36 ns on the reference.

- [ ] **Diagnose in the lane.** Add a diagnostics step (or a `stop_after=pre_place` dispatch
      with an extra report) that runs on the `pre_place` checkpoint of both netlists:
      `report_activity_annotation`; `report_power -instances` for the top contributors;
      `get_property` activity on `rst_ni`, the test-mode and boot-mode inputs, and a sample of
      flip-flop Q pins in CVA6, the LLC and the coprocessor; and a `report_power` per
      hierarchy (`i_keccak_cvxif`, `i_keccak_mmio`, `gen_cva6_cores`). The netlist exists
      only in the self-hosted VM's synth cache, so this is the cheap path. A local synthesis
      needs > 35 GB RAM and ~2.5 h.
- [ ] **Isolate the trigger.** If the diagnostics do not name it, compare a netlist with only
      `keccak_cvxif` (synth run `37005575294`'s tree, task 5.3) and one with only
      `keccak_mmio`, to see which change sets it off.
- [ ] **Fix or document.** Fix it in the RTL or flow if it is a real defect (e.g. a stuck
      net). If it is an OpenSTA propagation artefact, record it, and set an explicit
      `set_power_activity` default in `scripts/reports.tcl` so the lane's power reports are
      comparable across netlists.
- [ ] **Re-measure.** Re-run the SoC power figures for the reference and the both-arms
      netlist on the same settings, and update `sha3-cvxif-coprocessor` task 5.4.

---

## Phase 16 — Odd exit codes hang the JTAG-preload flow *(finding, 2026-10-01, worked around)*

Found on the Xcelium lane (`sha3-cvxif-coprocessor`): a program that returns an **odd** exit
code is reported `TIMEOUT`, not `FAIL`. Exit probes: `return 0` → `PASS`, `return 2` →
`FAIL 2`, `return 1` → `TIMEOUT`.

Cause, in upstream Cheshire (v0.3.1):

- crt0's `_exit` writes `(code << 1) | 1` to `SCRATCH[2]` and then `ret`s into its caller.
  Under JTAG preload, that caller is the bootrom's passive-boot loop.
- That loop (`hw/bootrom/cheshire_bootrom.c`, `boot_passive`) takes **bit 1** of `SCRATCH[2]`
  as its "start" flag, which is bit 0 of the exit code. When it sees the flag it clears
  `SCRATCH[2]` and jumps to the entry in `SCRATCH[1:0]`.
- So every odd exit code is erased before the VIP's end-of-computation poll (bit 0) sees it,
  and the run hangs until the simulated-time bound.

This affects every lane that uses the JTAG-preload flow: Xcelium, and Questa through the same
VIP. It violates the `xcelium-sim` spec's "Failing program reported as FAIL" scenario for odd
codes; even codes are fine.

- [x] Workaround in the project's own programs: `sw/include/newt_test.h` `newt_exit_code()`
      returns `2 × failures`, which is always even.
- [ ] Proper fix through the Cheshire fork (ADR-0002): either have crt0 not return into the
      bootrom after reporting, or have `boot_passive` use a flag bit that cannot collide with
      the EOC encoding. Upstream Cheshire tests all `return 0` on success, which is why this
      never showed there.

---

## Phase 15 — `IG_CVA6_PKG_PARAMS` only partly reaches the core *(finding, 2026-10-01, not acted on)*

Found while enabling CV-X-IF (`sha3-cvxif-coprocessor` task 1.1). CVA6's configuration has two layers:

- **Package-level constants** in `cv64a6_imafdcsclic_sv39_config_pkg.sv`, read by
  `ariane_pkg`/`riscv_pkg`/the hpdcache params: cache sizes and ways, D-cache type, scoreboard
  entries, user widths, `XLEN`. `iguana.mk`'s `IG_CVA6_PKG_PARAMS` rewrite **does** change these.
- **The `cva6_cfg_t` struct** passed as `cva6 #(.CVA6Cfg(...))`: `RVH`, `RVB`, `CvxifEn`, `RVZCB`,
  PMP and BTB/BHT sizes, …. Cheshire builds this itself in `gen_cva6_cfg()` and overrides the
  package default, so `IG_CVA6_PKG_PARAMS` has **no effect** on these fields.

**Consequence: the hypervisor extension is ON in the baseline.** `iguana.mk` sets
`CVA6ConfigHExtEn=0` ("deactivate hypervisor extension (large and not needed)"), but Cheshire
hard-codes `RVH : 1`. Confirmed by evaluating `cheshire_pkg::gen_cva6_cfg(iguana_pkg::CheshireCfg)`
in a Verilator probe: `RVH=1 RVB=0 CvxifEn=1` (on the `sha3-cvxif-coprocessor` branch). This is
**not** a regression from the Cheshire v0.3.1 bump (#48): the pre-bump revision `4a270af` also has
`RVH : 1`. So `synth-baseline.json` (735,953 cells / 17.77 mm²) and every PPA number so far
include the H extension.

- [x] Decide whether the thesis baseline should be H-off. **Decided 2026-10-02: keep H on**
      ([ADR-0004](adr/adr-0004-keep-cva6-hypervisor-extension.md)); newt stays on fork tag
      `newt.2`, with no H field. Original item:
      decide whether the thesis baseline should be H-off. If so, add a `Cva6RVH`-style field next
      to `Cva6CvxifEn` in the Cheshire fork, set it in `iguana_pkg`, and re-run the synth
      adoption gate. This moves the baseline, so it must land **before** any coprocessor PPA
      delta is quoted, or the delta must be measured against an H-on baseline and stated as such.
- [ ] Audit the rest of `IG_CVA6_PKG_PARAMS` for other struct-level no-ops. The current list is all
      package-level except `CVA6ConfigHExtEn`, but it should be re-checked whenever it is edited.
- [x] Fix or remove the misleading `CVA6ConfigHExtEn=0` line and its comment in `iguana.mk`.
      The line stays (harmless), and its comment now says H stays on and points to ADR-0004.

---

## Risks

| Risk | Mitigation |
| --- | --- |
| Questa → Verilator port is hard (Cheshire TB, hyperbus / DDR models) | Start with the coprocessor unit TB; accept synth-lane-only full-SoC sim initially |
| OpenROAD bump breaks `chip.tcl` command APIs | Budget 2–3 days in Phase 1; keep the 2024 image as fallback |
| Golden-image drift on every tool bump | No golden image exists — Packer is deferred out of Phase 6 to its own change. The host is instead reproduced from `infra/azure/provision-runner.sh`, which pins nothing and resolves the Actions runner release at run time, so a rebuild picks up current versions rather than drifting from a stale image. The trade-off is cold-start pull cost on every rebuild |
| Azure cost creep | Deallocate always (Phase 5's `stop` job plus the hourly `vm-watchdog.yml`) — the fixed 10:00 UTC auto-shutdown backstop no longer exists, deleted 2026-09-16 once both mechanisms were observed working for real (`post-merge-ci-verification` tasks 4.1/5.1); a $150/month resource-group budget alerting at 50/80/100 % of actual spend (Phase 6). Spot was dropped — P&R cannot survive an eviction and the synth lane alone does not justify a second VM. Measured: 10 P&R bring-up runs cost ≈ $193 in VM time; Phase 9's own verification runs measured ≈ $33/full run (Run A, 27h4m at $1.216/h) and ≈ $0.35 per resume-slice dispatch (~12 min) |
| Synth cache key over-includes: it hashes tracked-Makefile-input tree hashes (`Bender.{yml,lock}`, `hw/`, `target/ihp13/{yosys,pickle,pdk,src}`, `Makefile`, `iguana.mk`, `tools.mk`) rather than only the paths that actually feed synthesis, so an unrelated root-`Makefile` change (e.g. PR #18's `include apm.mk`) invalidates the key and forces a full ~3h resynthesis plus strands the previous key's Blob checkpoints (`post-merge-ci-verification` design Risks; hit for real 2026-09-13→15, run 34783899813) | Accepted — over-inclusion only costs a redundant resynthesis, never a stale netlist, which is the failure mode that actually matters (`pnr.yml`'s own cache-key comment). Narrowing the key to only the synth-relevant subset is a small, isolated follow-up once there's time to enumerate exactly which included paths never affect `synth-all`'s output |
| A Bicep `what-if` preview is necessary but not sufficient: several VM properties (`securityType`, `ssh.publicKeys`, `osDisk.diskSizeGB`) show as a benign property-level `Create` in the preview but fail the real deployment with `PropertyChangeNotAllowed` once they'd need to change an existing VM. Separately, a template-declared SKU can be unavailable in-region (`Standard_B2s` doesn't exist in `swedencentral`) or region-available with zero subscription quota (`Standard_B2s_v2`), and a `securityType` value can need an unregistered preview feature (`Microsoft.Compute/UseStandardSecurityType`) even for a brand-new VM | Before trusting a preview on an *existing* resource, diff every leaf the template sets against the live `az … show` and treat "absent on live" as the danger signal — that is what actually catches `PropertyChangeNotAllowed` (`azure-infra-as-code` design.md Risks, task 2.2). Before picking a VM size for a *new* resource, check `az vm list-skus` and `az vm list-usage` in-region rather than assuming a size from another region or plan works here (`infra/azure/README.md`) |
| `detailed_route` never converges on the modified design | It is congestion-bound at 63 % util even for stock Basilisk; treat a clean route as a stretch goal, not a gate. Consider a secondary easier PDK (Sky130) for fast QoR during development |
| Phase 1 adoption gate's ~1% cell/area delta has an unexplained residual: a ~830-module textual divergence in the pickled RTL (`sv2v.v`) between the 2024 baseline and the new image. Ruled out: bender release-asset choice (verified byte-identical `sources.json` from both `v0.27.4` assets on identical input) and the `TARGET_*` bender-version schema difference (those defines aren't referenced anywhere in the dependency tree). Not yet distinguished: pure module-reordering in morty's output vs. an actual semantic difference | Not blocking — delta is small and in the benign direction (design got smaller), 0 yosys `CHECK` problems both sides. Revisit if a future gate shows a similar or larger delta; a sort-and-diff-by-module pass on `sv2v.v`, or re-running pickle against a `bender 0.32.1`-shaped `sources.json`, would isolate it |
| 2024 baseline's own `sources.json` was generated by a host-installed `bender 0.32.1`, not either Docker image's bundled `0.27.4` — a pre-existing baseline-generation inconsistency, discovered while investigating the row above | Note for future baseline captures: regenerate references fully in-container with the pinned tool versions, not via whatever `bender` happens to be on the host PATH |
| Synthesis QoR moved +3.05% cells / +3.60% area when yosys went 0.40→v0.69, because `abc -liberty_args "-S 20 -G 3"` had to be dropped (it segfaults v0.69 — see Phase 12 / design D9). That flag gave ABC a slew/gain delay model instead of a unit one | Accepted deliberately; `synth-baseline.json` reseeded from adoption-gate run 35275581702 so later design work is measured against the tool that synthesises it. Any thesis PPA figure quoted against the older 714,166-cell baseline must be requoted. Recovering the delta is item 1 of Phase 12's PPA improvement list |

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
   jobs — the docker-compose container exits on its own. **Superseded for CI work**: driving
   the runner by hand this way destroyed two runs when `synth.yml`'s schedule fired through
   it and `actions/checkout` wiped the shared workspace. Go through `pnr.yml` instead —
   `PNR_RESUME_EXCLUDE` + `PNR_STOP_AFTER` re-run a single stage in minutes.

**Status: all of the above are baked in** — 3 and 4 in `scripts/pnr/common.tcl`
(`pnr_apply_routing_layers` is called by every routing stage, and no run has hit DRT-0155
since). Bring-up added more of the same class, all stemming from one property of the staged
architecture: **each stage is a fresh process, so anything the old single-process `chip.tcl`
set once must be re-derived per stage.** Concretely — `set_thread_count` (OpenROAD defaults to
**1 thread**; missing it left six of eight stages single-threaded), `set_wire_rc` before CTS
(RSZ-0089), `estimate_parasitics -global_routing` before any post-route repair, and
`load_checkpoint`'s `unzip` needing `-o` (a re-load prompts interactively and silently skips
in a headless run). Two further traps worth knowing: OpenROAD's `-log` output is
block-buffered, so a stage can look hung for hours while pinning 15 cores — check the process,
not the log; and streaming a `-verbose` stage's stdout into the Actions live log can kill the
runner's connection outright (`grt`'s ~5,472 net names in <50 ms did exactly that). Full
per-stage detail lives in `docs/pnr-pipeline.md`.
