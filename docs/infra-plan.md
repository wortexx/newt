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
| OpenROAD is upstream (`589dee1c8`, ~mid-2024) | **Bumped to `2c56926` (2026-08-27) in `newt-eda`.** "Safe to bump" held, but the 2.5-year API gap needed real porting work: `initialize_floorplan -sites`→`-site`, `detailed_route`'s `-bottom/-top_routing_layer` now hard errors (DRT-0509/0510, use `set_routing_layers`), PDN zero-instance crashes, per-process `set_wire_rc`/`estimate_parasitics`/`set_thread_count`. **Lesson: check a command's proc body, not its `define_cmd_args`** — the deprecated flags are still declared and parsed, and only the body rejects them. Backend instability was *not* all OpenROAD: see the routability blocker in Phase 11. |
| Simulation is **Questa-only** (`iguana.mk` → `questa-2022.3 vsim`); no Verilator flow | **Critical-path blocker for RTL CI.** Must add Verilator. |
| Dev machine has 31 GB RAM; synth peaks ~35 GB | Basilisk synth needs a >64 GB box or a swap file. |
| Stock `chip.tcl` does not complete unattended | Still true, but **the specific failure modes did not reproduce**: across 10 real P&R runs `remove_buffers` **never crashed once** (the "~1/3 runs" figure is unsubstantiated in this environment — the retry was ultimately verified by deliberate fault injection, not by a real crash). `repair_timing` looping forever did reproduce, and post-route repair is now skipped entirely. The real unattended blockers turned out to be elsewhere: `repair_antennas` hanging ~14h single-threaded, and global route's congestion iterations. |
| Basilisk WNS ≈ −2.5 ns vs 6 ns target | Design does not close timing in the open flow (known / accepted). **Caveat for any PPA number quoted from the CI lane**: with `grt_repair` skipped (Phase 5), measured WNS at `grt` is **−14.76**, not −2.5 — post-route repair is exactly what closes that gap. Restore a bounded `grt_repair`, or requote the baseline, before using lane output as thesis PPA data. |
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

Phase 5+6  ──►  Phase 9  (post-merge CI verification — gated on `ci-pnr-lane` landing)
Phase 10 (Actions version upgrade)  — independent maintenance, any time
Phase 11 (backend routability)      — design work; gates a detail-routed DEF, nothing else
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
- [ ] **Naming:** keep `PROJ_NAME` / `RTL_NAME = basilisk` internally for now — many scripts
      hardcode it (`basilisk.sdc`, checkpoint/report paths). Optional dedicated rename PR later.
- [ ] **Dependency strategy** for modified IP: fork `cheshire` (un-tie cvxif port) and,
      when needed, `cva6` (`CvxifEn=1` / `Zknh`); point `Bender.yml` at the forks + commits.
      Prefer forks over `pickle/patches/` for anything beyond a one-line change.

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
- [x] **Kept pinned**: yosys fork `3ce5059`, morty `v0.9.0`, svase `f5f5290`, sv2v `v0.0.11`,
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
- [ ] **Not yet done — adoption decision pending**: flip `docker-compose.yml`/`use-docker.sh`
      to `newt-eda:dev` as the default dev image. Gate passed; flipping the default is a
      separate call the user makes deliberately, not an automatic consequence of a green gate.
- [ ] Expect 2–3 days adapting `chip.tcl` to newer OpenROAD command APIs
      (`remove_buffers` now requires instance args; `repair_timing` / `global_route` /
      `detailed_route` flags moved; GUI / `save_image` changes) — not attempted yet; this
      phase only had to prove the yosys synth path, not full P&R.
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
      see Phase 0 above). `sim-unit`, `sim-soc`, and `synth-coproc` are intentionally
      scaffolded stubs — each runs its real precondition check every run and reports which
      blocker is still open (no Phase 7 coprocessor RTL yet; the `verilator-sim-flow`
      JTAG-DM bug, deferred per that change's tasks.md) — but always exits 0 and is not a
      required check until it graduates via a dedicated follow-up, never automatically.
      Full planning record: `openspec/changes/ci-fast-lane/`.

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
phase has now superseded (disabled, and deleted only once Phase 9 observes the watchdog
working — never a window with no backstop).

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

**Drift and the one undeclared resource.** Incremental deployments never delete, so a
hand-made resource simply persists; `infra/azure/README.md` documents the
`az resource list` drift check. Exactly one live resource is deliberately *not* declared:
the DevTestLab schedule `shutdown-computevm-newt-synth-runner`, currently disabled.
Phase 9 deletes it once `vm-watchdog.yml` has been observed working, so that there is
never a window with no cost backstop.

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

## Phase 9 — Post-merge CI verification  *(unblocks only once `ci-pnr-lane` lands on `main`)*

Several P&R-lane acceptance items are **not** verifiable from a feature branch, for one
GitHub-side reason: a workflow's `schedule` and `workflow_dispatch` triggers are only
registered once the workflow file exists on the repository's **default branch**. Tag pushes
are exempt (any ref's push evaluates the workflows in that ref's tree), which is why the whole
bring-up ran off `pnr-bringup-*` tags. So these are deferred by sequencing, not by difficulty:

- [ ] Real `workflow_dispatch` run of `pnr.yml` (the bring-up used tag pushes throughout —
      `gh workflow run pnr.yml` 404s pre-merge, and `pnr.yml` doesn't even appear in
      `gh workflow list`). Confirms the `resume_from_run` input path, which has never run.
      Still open — `azure-infra-as-code` exercised `vm-watchdog.yml`, not `pnr.yml`.
- [x] `vm-watchdog.yml`'s hourly cron actually firing, and its OIDC login /
      power-state check succeeding unattended. **Observed (2026-09-13), during
      `azure-infra-as-code` task 2.4**: one manual `workflow_dispatch` plus two
      unprompted scheduled runs (11:20, 14:10, 17:59 UTC) all completed
      successfully via `Azure login (OIDC)` → `Check VM power state` →
      `Nothing to do`.
- [ ] One observed correct **idle-deallocate** (the `Deallocate idle VM` step
      actually running). Still open: the VM was deallocated for all three runs
      above, so that step has never executed — this is the one half of the
      original bullet that direct observation didn't reach.
- [ ] **Only after** an observed correct idle-deallocate: delete the Azure fixed
      auto-shutdown (currently `status: Disabled` by hand, not removed — reconfirmed
      2026-09-13) and enable the weekly `pnr.yml` cron. Never leave a window with no
      cost backstop at all.
- [ ] Re-enable the `CI Synth Lane` schedule (`gh workflow enable`) — disabled during
      bring-up so its nightly runs stopped competing for the single runner.
- [ ] Coexistence guard under a **real** overlap: with a P&R run active, trigger a synth-lane
      dispatch so a run queues, and confirm `pnr.yml`'s `stop` job skips deallocation with a
      clear log line and the queued synth job then runs. Deferred here because it wants both
      lanes' schedules live, which is only true post-merge. (The other half of that check
      needs revisiting: this section originally said `main` had no branch protection, so no
      P&R job could be a required check — that changed before `azure-infra-as-code` started;
      `main` now requires `lint` and `sw` (confirmed live, 2026-09-13). Neither `pnr.yml` nor
      `synth.yml` is in that list, and neither has a `pull_request` trigger, so this coexistence
      guard is unaffected — but the stale claim is corrected here rather than left standing.)
- [ ] Update `synth.yml`'s header comment and this document's Phase 5 section to the
      post-watchdog reality: VM deallocated by default, started by `pnr.yml`, watchdog
      cleans up, fixed auto-shutdown gone.

## Phase 10 — GitHub Actions version upgrade  *(maintenance, deadline-driven)*

Every action pinned across `ci.yml` / `synth.yml` / `pnr.yml` / `docker-image.yml` declares
the **Node 20** runtime, which GitHub deprecated. Runners have defaulted to Node 24 since
2026-06-16 and **already force these actions onto it** (that is the warning in every run log);
Node 20 is removed entirely on **2026-09-23**. Nothing in this repo breaks on that date — the
forcing is what we already run on, and we never set the `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION`
opt-out — but every action here is several majors behind, and each has a Node 24 release:

| action | pinned | latest | uses |
| --- | --- | --- | --- |
| `actions/checkout` | v4 (x8) | v7.0.1 | node20 → node24 |
| `actions/upload-artifact` | v4 (x4) | v7.0.1 | node20 → node24 |
| `azure/login` | v2 (x5) | v3.1.0 | node20 → node24 |
| `docker/build-push-action` | v6 (x6) | v7.3.0 | node20 → node24 |
| `docker/setup-buildx-action` | v3 | v4.3.0 | node20 → node24 |
| `docker/login-action` | v3 | v4.6.0 | node20 → node24 |

- [ ] Upgrade one action at a time, letting the per-PR fast lane validate `checkout` and
      `upload-artifact` first — it runs on every push and costs nothing.
- [ ] Watch for real breaking changes across three majors: `fetch-depth: 0` behaviour,
      `if-no-files-found` semantics, artifact immutability.
- [ ] Leave `azure/login` for last: its failure mode is a VM that won't start, which costs a
      whole P&R run to discover.
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
- [ ] **Lower `gpl` density** from `-density 0.65`, trading area for routability.
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

## Risks

| Risk | Mitigation |
| --- | --- |
| Questa → Verilator port is hard (Cheshire TB, hyperbus / DDR models) | Start with the coprocessor unit TB; accept synth-lane-only full-SoC sim initially |
| OpenROAD bump breaks `chip.tcl` command APIs | Budget 2–3 days in Phase 1; keep the 2024 image as fallback |
| Golden-image drift on every tool bump | No golden image exists — Packer is deferred out of Phase 6 to its own change. The host is instead reproduced from `infra/azure/provision-runner.sh`, which pins nothing and resolves the Actions runner release at run time, so a rebuild picks up current versions rather than drifting from a stale image. The trade-off is cold-start pull cost on every rebuild |
| Azure cost creep | Deallocate always (Phase 5's `stop` job plus the hourly `vm-watchdog.yml`); a $150/month resource-group budget alerting at 50/80/100 % of actual spend (Phase 6). Spot was dropped — P&R cannot survive an eviction and the synth lane alone does not justify a second VM. Measured: 10 P&R bring-up runs cost ≈ $193 in VM time |
| A Bicep `what-if` preview is necessary but not sufficient: several VM properties (`securityType`, `ssh.publicKeys`, `osDisk.diskSizeGB`) show as a benign property-level `Create` in the preview but fail the real deployment with `PropertyChangeNotAllowed` once they'd need to change an existing VM. Separately, a template-declared SKU can be unavailable in-region (`Standard_B2s` doesn't exist in `swedencentral`) or region-available with zero subscription quota (`Standard_B2s_v2`), and a `securityType` value can need an unregistered preview feature (`Microsoft.Compute/UseStandardSecurityType`) even for a brand-new VM | Before trusting a preview on an *existing* resource, diff every leaf the template sets against the live `az … show` and treat "absent on live" as the danger signal — that is what actually catches `PropertyChangeNotAllowed` (`azure-infra-as-code` design.md Risks, task 2.2). Before picking a VM size for a *new* resource, check `az vm list-skus` and `az vm list-usage` in-region rather than assuming a size from another region or plan works here (`infra/azure/README.md`) |
| `detailed_route` never converges on the modified design | It is congestion-bound at 63 % util even for stock Basilisk; treat a clean route as a stretch goal, not a gate. Consider a secondary easier PDK (Sky130) for fast QoR during development |
| Phase 1 adoption gate's ~1% cell/area delta has an unexplained residual: a ~830-module textual divergence in the pickled RTL (`sv2v.v`) between the 2024 baseline and the new image. Ruled out: bender release-asset choice (verified byte-identical `sources.json` from both `v0.27.4` assets on identical input) and the `TARGET_*` bender-version schema difference (those defines aren't referenced anywhere in the dependency tree). Not yet distinguished: pure module-reordering in morty's output vs. an actual semantic difference | Not blocking — delta is small and in the benign direction (design got smaller), 0 yosys `CHECK` problems both sides. Revisit if a future gate shows a similar or larger delta; a sort-and-diff-by-module pass on `sv2v.v`, or re-running pickle against a `bender 0.32.1`-shaped `sources.json`, would isolate it |
| 2024 baseline's own `sources.json` was generated by a host-installed `bender 0.32.1`, not either Docker image's bundled `0.27.4` — a pre-existing baseline-generation inconsistency, discovered while investigating the row above | Note for future baseline captures: regenerate references fully in-container with the pinned tool versions, not via whatever `bender` happens to be on the host PATH |

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
