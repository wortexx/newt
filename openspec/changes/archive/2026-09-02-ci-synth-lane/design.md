## Context

See proposal.md for motivation. Constraints that shape the approach:

- The flow is `make ig-hw-all && make pickle-all && make synth-all` from the repo root (all three reachable there — `Makefile` includes `iguana.mk`, which includes `target/ihp13/{pickle/pickle.mk,yosys/yosys.mk}`). Appendix B of `docs/infra-plan.md`: `synth-all` does **not** trigger a pickle rebuild (hence the explicit `pickle-all`), the hierarchical flow (`run-yosys-hier`) is broken on this design, and `sources.json` must be regenerated in-container — automatic here, since `pickle-all` regenerates it on a fresh CI checkout.
- Measured profile (Phase 1 adoption gate, same image): ~2 h 28 m wall, 29.6 GB peak RAM, outputs ~1.5 GB (netlist 127 MB). Well inside a 64 GB large runner and GitHub's 6 h job cap, with margin for `ig-hw-all`/pickle (~30–40 min more).
- Reports produced by `synth-all` (in `target/ihp13/yosys/reports/`): `basilisk_synth.rpt` (yosys `check` — the "0 problems" gate), `basilisk_area.rpt` (yosys `stat` with liberty: cell count, chip area, per-cell-type counts → DFF count), `basilisk_area_logic.rpt`. Timing is *not* produced by `synth-all`; `run-sta` exists for that (D4).
- The fast lane (`ci.yml`) already solved container-job papercuts this lane inherits: `bash` as default shell, `git config safe.directory`, and the retry-with-clean-`.bender/` pattern for the flaky buildroot.net submodule clone. Reuse those verbatim.
- Phase 1 gate numbers seed the baseline: 714,166 cells, 17,156,844.69 µm² chip area, 89,258 DFFs; WNS ≈ −2.5 ns is the known/accepted timing state.

## Goals / Non-Goals

**Goals:**

- A single new workflow that gives a daily (and on-demand) answer to "does the full synth flow still complete, is the design still clean, and how far have the numbers moved?"
- Zero changes to the flow itself; zero new infrastructure (no self-hosted runners, no cloud).
- Metric comparison that a future change (e.g. the coprocessor landing) can read historical values from — artifacts + summaries, baseline in git.

**Non-Goals:**

- P&R / OpenROAD (Phase 5's P&R lane itself) — this lane stops at the mapped netlist + STA. (The VM this lane now runs on is shared groundwork for that later lane — see D1 — but running P&R on it is out of scope here.)
- Gating anything: no required checks, no fail-on-drift budgets (Phase 3's `synth-coproc` budget idea stays there).
- Full Phase 6 IaC (Terraform/Bicep, OIDC federated credential, Packer golden image, auto-deallocate automation) — deferred; this change provisions the minimum VM + runner registration by hand, documented so Phase 6 can formalize it later.
- Baseline auto-update or trend dashboards.

## Decisions

### D1: Self-hosted Azure VM, pulled forward from Phase 5 — large-runner path ruled out

**Superseded during implementation (2026-09-02).** The original plan below was to use a GitHub-hosted larger runner, confirming availability as task 1.1 before building on it. That check ran and failed: `wortexx/newt` is owned by a personal GitHub user account, and GitHub's hosted larger-runners feature is exposed only via `/orgs/{org}/actions/hosted-runners` — confirmed by `gh api /repos/wortexx/newt` (`owner.type: "User"`) and a 404 probing that endpoint directly. There is no personal-account path to it.

Of the three reroutes this design already anticipated — (a) move the repo into a free org, (b) pull Phase 5/6's self-hosted Azure VM forward, (c) a standard runner + swap (rejected as primary: 16 GB RAM + ~14 GB free SSD cannot absorb a 29.6 GB peak without pathological thrashing) — the user chose **(b)**.

**Scope of the pull-forward:** the minimum slice of Phase 5/6 needed for this lane to run at all — one manually provisioned VM (Standard_E16ds_v5 class: 16 vCPU / 128 GB, comfortably above the 29.6 GB peak) with Docker and a GitHub Actions self-hosted runner registered against `wortexx/newt`, label `self-hosted-synth`. Explicitly **not** pulled forward: Terraform/Bicep IaC, the OIDC federated credential, the Packer golden image, and the `start`/`stop` job pair that deallocates the VM between runs (Phase 6) — those stay real Phase 5/6 work, done properly later rather than half-built here. The VM stays running (or is stopped/started by hand) for now; D1a below adds a cost guardrail regardless.

**Region: `swedencentral`, not `westeurope`.** The initial default (matching this subscription's three pre-existing, unrelated resource groups) turned out wrong: `az vm list-skus` showed `Standard_E16ds_v5` and every other 16-vCPU candidate checked (`E16s_v5`, `E16_v5`, `E16as_v5`, `E16bds_v5`, `D16ds_v5`, `D16s_v5`) as `NotAvailableForSubscription` in `westeurope` on this subscription — a new-subscription SKU-access restriction, not a capacity issue (confirmed via a live check across five regions, task 1.1a). `northeurope`/`eastus` don't offer these SKUs at all in this check; `swedencentral` and `uksouth` have all of them available. No VM-size fallback was needed — `swedencentral` keeps the original Standard_E16ds_v5 choice, just in a different region.

**Blocked on a subscription.** The only `az` login available on the dev machine at implementation time was the user's employer's Azure tenant — not appropriate for a personal repo's public-facing CI infrastructure (cost/policy authorization is unclear, and a self-hosted runner on a public repo is a real security surface to place inside a corporate tenant; see D1b). No VM is provisioned until the user supplies a personal-appropriate subscription. Tasks 1.1a/1.1b are written but held at "not started" for this reason — this is a genuine external dependency, not an oversight.

*Alternative considered:* self-hosted from day one, before even trying GitHub-hosted — rejected initially since the plan explicitly sequenced Azure last (highest effort, lowest frequency); revisited only because the higher-effort path turned out to be the only available one.

### D1a: Manual VM lifecycle for now, with a cost tripwire

Without Phase 6's `start`/`stop` automation, an always-on E16ds_v5 is a real, continuous cost. **Corrected against the Azure retail-prices API (task 1.1c):** the rough calculator estimate above ($500–700/mo) undersold it — real on-demand compute for `Standard_E16ds_v5`/`swedencentral` is $1.216/hour (~$888/mo if always-on), plus ~$26/mo flat for the OS disk and static IP that bill even while stopped — well above the ~$50–150/mo the plan's Risks table budgeted for the *eventual*, spot-and-deallocate Phase 5/6 setup. User confirmed (task 1.1c): manual stop/start discipline is the operating mode, not always-on. Two mitigations, both manual for this change: (1) the VM is stopped/deallocated by hand between planned uses rather than left running continuously, documented as an operational note in the workflow's header comment and in `docs/infra-plan.md`; (2) task 1.1c is a deliberate cost check-in before the first unattended (nightly-cron) run is enabled — the nightly trigger is added to the workflow but the user confirms the always-on cost is acceptable, or the manual stop/start discipline is in place, before it's allowed to fire against a real VM. `workflow_dispatch` and label-triggered runs proceed without that gate since they're inherently attended.

**Gap found the hard way (task 3.3, second verification run):** "inherently attended" only describes how a `workflow_dispatch`/labeled-PR run *starts* - it says nothing about whether the VM stays up long enough for it to *finish*. The 10:00 UTC auto-shutdown is a blunt, unconditional daily event: it fires regardless of trigger type, and its buffer math (D2) only accounts for the nightly cron's fixed 02:30 UTC start time, not a dispatch that could be kicked off at any hour. A dispatch at 09:36 UTC ran cleanly through `ig-hw-all`/`pickle-all` and was 24 minutes into `synth-all` when the auto-shutdown deallocated the VM out from under it - the job showed as `cancelled`, not `failed`, and the VM came back up in `VM deallocated` state needing a manual `az vm start` before anything could run again. No workflow-level guard catches this (a self-hosted-runner VM disappearing looks identical, from the workflow's side, to any other infra failure). **Operating note, not a design fix:** before dispatching or expecting a labeled-PR run to complete, check that enough of the ~2.5–3h window remains before the next 10:00 UTC - in practice, don't start one after roughly 06:30 UTC same-day. A real fix (disabling the schedule around a planned run, or Phase 6's actual lifecycle automation) is future work, not part of this change's scope.

Concretely, `az vm auto-shutdown` provides a one-way daily-deallocate safety net (stops the VM if it's still running at a fixed UTC time; does not restart it — there's no matching auto-start). Its time **must sit after** D2's nightly-cron window's worst case, not just its typical case: cron fires at 02:30 UTC, and the workflow's own hard `timeout-minutes: 350` ceiling (D2) means a run could legitimately still be going until 08:20 UTC. Auto-shutdown is set to **10:00 UTC**, a 1h40m buffer past that ceiling — found and fixed during task 1.1a's runbook (an earlier default of 22:00 UTC would have killed the VM hours before a 02:30 cron run could ever complete, silently breaking the nightly lane the moment it was enabled).

### D1b: Public-repo self-hosted-runner exposure — gate fork PRs, don't just gate labels

A self-hosted runner registered against a **public** repository is a documented GitHub risk independent of which cloud it lives in: a pull request from an external fork can carry workflow-triggering changes, and by default a labeled fork PR would execute on this runner with whatever access the runner has (network, any repo secrets in scope) — materially worse here than a throwaway GitHub-hosted VM since this one sits on infrastructure the user provisions and pays for directly. The `full-synth` label alone (this change's original trigger condition) is not a sufficient gate: label-add permission doesn't by itself prevent a malicious fork PR's *code* from being what gets checked out and built once labeled.

Mitigation, layered:

1. **Repo setting** (task 1.1d): enable "Require approval for all outside collaborators" (Settings → Actions → General → Fork pull request workflows) — this is GitHub's own built-in gate specifically for this scenario: a fork PR's workflow run targeting a self-hosted runner sits pending until a maintainer approves that specific run, every time.
2. **Workflow-level check** (folded into task 3.1): the label-triggered job additionally requires `github.event.pull_request.head.repo.full_name == github.repository` (i.e., the PR is from a branch of this repo, not a fork) *or* the repo-setting approval gate above — belt-and-suspenders, and makes the constraint visible in the workflow file itself rather than only in a settings page.
3. Nightly and `workflow_dispatch` triggers are unaffected — both only ever run trusted, already-in-repo content.

This becomes a spec-level requirement (see the specs delta) since it's externally observable behavior a fork contributor or reviewer needs to be able to rely on, not just an implementation nicety.

### D2: Separate workflow file, three triggers, per-ref concurrency

`.github/workflows/synth.yml`, not new jobs in `ci.yml`: different triggers, different runner, different cost profile, and `ci.yml`'s header contract ("runs on every push/PR") stays true.

- `schedule: cron '30 2 * * *'` (02:30 UTC nightly; arbitrary off-peak pick, assumption recorded) — held behind the D1a cost check-in before first enabled against a real VM.
- `workflow_dispatch:` (runs on whatever ref is selected in the UI).
- `pull_request: types: [labeled, synchronize, reopened]` with a job-level `if:` requiring both the `full-synth` label present *and* (per D1b) `github.event.pull_request.head.repo.full_name == github.repository` — covers "label added now" and "push to an already-labeled PR" for same-repo branches only; a labeled fork PR does not run here regardless (it still hits the repo-setting approval gate as a second layer). (`opened` is deliberately absent: a PR cannot be born labeled via the UI; labeling after open fires `labeled`.)
- `concurrency: group synth-${{ github.ref }}, cancel-in-progress: true` — a superseded run of a 3 h job is pure wasted VM time; nightly and PR refs land in different groups so they don't cancel each other.
- `timeout-minutes: 350` — matches the plan's expectation of ~3 h; on a self-hosted VM there's no hard 6 h platform cap, but the timeout still bounds a hung run so it doesn't tie up the single VM (`concurrency` already serializes same-ref runs, but a stuck run would otherwise block every other ref indefinitely too).

### D3: One job, sequential steps — not a job per flow stage

`ig-hw-all` → `pickle-all` → `synth-all` → `run-sta` → summarize, as steps of a single `synth` job. Splitting into jobs would mean shipping multi-GB intermediates between runners and paying large-runner spin-up repeatedly, for no parallelism gain (the stages are strictly sequential). A failed step fails the job at the right place, and the always-upload step (D6) still captures logs.

### D4: WNS via the existing `run-sta` target — no override needed

`yosys.mk` already has `run-sta` (OpenSTA script → `report_checks` per clock group). This design originally speculated the image might lack a standalone `sta` binary; **verified false during task 1.2**: `newt-eda:dev` ships `sta` at `/build/bin/sta` (confirmed via `command -v sta` and a real run), so `run-sta`'s default `STA ?= sta` works unmodified — no `STA="openroad -exit"` override, and no image rebuild.

Two real wrinkles, both handled in the workflow (task 3.1), neither needing a flow change:

1. `opensta_timings.tcl` does `read_sdc ../openroad/src/basilisk.sdc` — relative to the *cwd*, so `run-sta` must be invoked with cwd `target/ihp13/yosys` (`make -C target/ihp13/yosys -f yosys.mk run-sta`), matching how `yosys.mk`'s own recursive invocations cd there. Confirmed the referenced SDC exists at that relative path (`target/ihp13/openroad/src/basilisk.sdc`), and confirmed the `sta` binary's `report_checks` output format directly against a throwaway netlist+liberty+SDC in-container (`slack (MET)`/`slack (VIOLATED)` lines, e.g. `           4.31   slack (MET)`) — this is the exact string `synth_metrics.py` (D5) parses.
2. **`RTL_NAME=basilisk` must be passed explicitly** — caught while writing task 3.1's workflow, not in task 1.2's verification. This standalone `make -f yosys.mk` call does not go through `iguana.mk` (a separate make invocation, not a sub-make of the `ig-hw-all`/`pickle-all`/`synth-all` chain), which is where `RTL_NAME ?= basilisk` is set; without the override, `yosys.mk`'s own default (`RTL_NAME ?= TOP_DESIGN = iguana_chip`) applies instead, and `run-sta` would look for a netlist named after the wrong project name entirely — silently missing what `synth-all` actually produced rather than erroring clearly. Task 1.2's original "no env override" note undersold this: it correctly ruled out needing `STA=`, but didn't check for this separate variable.
3. **`PICKLE_OUT=../pickle/out` must also be passed explicitly** — found via a real end-to-end run (task 3.3), not anticipated in planning. `PICKLE_OUT` is only ever defined in `pickle.mk`, which this standalone invocation also doesn't include; without it, `SV2V_FILE := $(PICKLE_OUT)/$(RTL_NAME).sv2v.v` (one of `run-sta`'s prerequisites via `$(NETLIST)`) resolves to the bogus path `/basilisk.sv2v.v`, and `make` fails with "No rule to make target" before ever invoking `sta` — silently producing an empty `sta_output.txt` that looks identical to "STA ran and found nothing" rather than "STA never ran."
4. **A CI-only symlink is needed for `basilisk_instances.sdc`** — also found via a real run (task 3.3). `basilisk.sdc`'s own `source src/basilisk_instances.sdc` line was written assuming cwd `target/ihp13/openroad` (confirmed via `chip.tcl`'s real invocation: `read_sdc src/basilisk.sdc`, run from `openroad.mk`'s own directory) — directly incompatible with wrinkle 1's requirement of cwd `target/ihp13/yosys`. Fixed with `ln -sf ../../openroad/src/basilisk_instances.sdc target/ihp13/yosys/src/basilisk_instances.sdc` as a workflow step, created at runtime and never committed — makes the existing (inconsistent) convention resolvable without editing either flow script.

WNS is the worst (most negative, or smallest-margin MET) slack across the reported path groups. If STA still fails on the real full-chip run for an unanticipated reason, the summary degrades gracefully: WNS row shows "unavailable" and the job does **not** fail for that alone (the spec's failure conditions are flow failure and `CHECK` problems; STA is measurement, not validation) — but an STA *tool* failure is still surfaced loudly in the summary.

**This graceful-degradation path is where WNS actually landed for this change.** After wrinkles 1–4 above were all fixed, a fourth real run progressed well into `basilisk.sdc` before hitting `Error 2204: get_property is not an object` at line 90 — traced to `basilisk_instances.sdc` line 54's `set SLO_PHY_RCLK_REG [get_cells *ddr_rcv_clk_o*]`, a cell pattern matching nothing in this netlist (confirmed by the run's own `Warning 349: instance '*ddr_rcv_clk_o*' not found`). This is a genuine, pre-existing content bug in the SDC itself - not a path/prerequisite issue like 1–4, and fixing it means editing `basilisk.sdc`, which is out of this change's "flow invoked as-is" scope. Put to the user rather than fixed unilaterally: **decision was to accept WNS-unavailable and ship the lane as-is** (task 3.3), leaving the SDC's `*ddr_rcv_clk_o*` pattern as a tracked, deferred issue for whoever next touches P&R/timing work on this design - not silently forgotten, but consciously out of scope here.

### D5: Baseline = one checked-in JSON; extraction = one small script

- `target/ihp13/yosys/synth-baseline.json`: `{cells, chip_area_um2, dffs, wns_ps}` plus provenance fields (`source`, `date`, `image`) seeded from the Phase 1 adoption-gate run. Lives next to the flow that produces the numbers. Updated only by a human commit (spec requirement), e.g. after an intentional change like the coprocessor landing.
- `target/ihp13/yosys/scripts/synth_metrics.py` (python3 is in the image): parses `basilisk_area.rpt` (yosys `stat` → cell count, chip area; DFF count by summing the `sg13g2_df*` cell rows — same counting method as the Phase 1 gate, so deltas are apples-to-apples) and the STA output (worst slack), emits a Markdown table (metric / baseline / current / delta) to `$GITHUB_STEP_SUMMARY`, and separately checks `basilisk_synth.rpt` for yosys `CHECK`'s "found N problems", exiting non-zero iff N > 0 or a *required* report is missing/unparseable. Keeping CHECK-enforcement in the same script keeps the job's failure semantics in one reviewable place.
- The script takes paths as arguments and prints to stdout when `$GITHUB_STEP_SUMMARY` is unset, so it runs identically on a dev box against a local `reports/` dir — testable without a 3 h CI round trip. **Correction during implementation:** the Phase 1 gate's actual report files were not kept on disk (they live under gitignored `target/ihp13/*/out/`/`reports/` and were cleaned up after that run) — this design's assumption that they were "kept outputs" was wrong. Testing instead used fixture reports built to match the real format, captured from an actual `yosys stat`/`check` and `sta report_checks` run in-container against a throwaway design (task 1.2/2.1) and populated with the Phase 1 gate's recorded numbers. Real-gate-data validation happens for the first time at task 3.3's actual end-to-end run.

*Alternative considered:* parsing metrics in inline workflow bash — rejected; ~4 metrics across 3 report formats plus delta math is past the point where YAML-embedded shell stays honest, and a script is unit-testable offline.

### D6: Artifacts: netlist + reports, `if: always()` for reports, 30-day retention

Two uploads: `basilisk-netlist` (the ~127 MB mapped netlist; upload compresses it) on success of `synth-all`, and `synth-reports` (reports dir + top-level yosys log + STA output) with `if: always()` so a failed run still ships its diagnostics. `retention-days: 30` on both — nightly cadence makes ~30 netlists (~2–3 GB stored, transparently compressed) the steady state, and anything worth keeping longer gets promoted into git (baseline) or a release.

### D7: Reuse `ci.yml`'s container-job hardening verbatim

`container: ghcr.io/wortexx/newt-eda:dev`, `defaults.run.shell: bash`, the `safe.directory` step, and the 3-attempt clean-`.bender/` retry wrapped around the first target that triggers dependency checkout (`ig-hw-all` here). These were each earned through a real CI failure in the fast-lane change; not re-deriving them. Unaffected by the D1 pivot — `container:` on a self-hosted runner works the same way, provided the VM has Docker (part of its provisioning).

## Risks / Trade-offs

- **[No Azure subscription appropriate for this yet]** → **resolved.** The user supplied a personal-appropriate subscription; the VM (D1) is provisioned and the workflow (task 3.1) is live and verified.
- **[`basilisk.sdc`'s `*ddr_rcv_clk_o*` cell pattern doesn't match this netlist]** → **known, deferred, not fixed by this change.** Found via task 3.3's real end-to-end verification (see D4's addendum): `basilisk_instances.sdc` line 54 sets a cell reference via a pattern that matches nothing on `iguana_chip`, which crashes `report_checks` partway through and is why WNS reads "unavailable" rather than a real number. Fixing it means editing the flow's own SDC, out of this change's "flow invoked as-is" scope - user decision was to accept the graceful-degradation path (D4) rather than fix it here. Whoever next does P&R/timing work on this design will need this resolved regardless; not silently forgotten.
- **[Self-hosted VM on a public repo — fork PR code execution]** → mitigated via D1b's two-layer gate (repo approval setting + same-repo-only workflow condition); verified in task 1.1d/3.2 before the label trigger is considered safe to leave enabled.
- **[Always-on VM cost without Phase 6's deallocate automation]** → D1a's manual stop/start discipline plus a deliberate cost check-in (task 1.1c) before nightly cron is enabled unattended. Revisit sooner if Phase 6 IaC lands and brings the spot/deallocate automation forward.
- **[`:dev` image tag moves under the lane]** → accepted deliberately: the lane *should* test the current tooling (drift shows up as a metric delta with a visible cause in the image's own workflow history). The pinned date tag remains available for bisecting a suspicious delta.
- **[STA-in-container path/tool wrinkles (D4)]** → verified cheaply in-container before wiring (task 1.2); summary degrades to "WNS unavailable" rather than failing the flow's real deliverables.
- **[First real run diverges from the local Phase 1 gate numbers]** → expected to be near-zero delta (same image, same flow); if not, that's the lane doing its job — investigate before merging, since the baseline's credibility is the summary's whole value.
- **[Manually provisioned VM drifts from a future Phase 6 golden image / IaC definition]** → accepted for this change (Non-Goals); documented as a known gap for Phase 6 to formalize, not silently forgotten — task 4.1 records the manual steps taken so Phase 6 has a starting point.

## Open Questions

- Which Azure subscription to provision into — **blocking**, not deferrable; needed before task 1.1a can run. Not a "safely answered later" item; recorded here because it surfaced during implementation rather than planning.
- Exact nightly hour and whether weekend runs earn their cost — trivially tunable after a week of bills; 02:30 UTC daily to start.
- Whether label-triggered PR runs should also post a PR comment (vs. step summary only) — deferrable; step summary satisfies the spec, a comment step can be added later without touching semantics.
- Whether to keep the VM always-on or adopt manual stop/start discipline (D1a) — a judgment call on convenience vs. cost the user can make once real Azure pricing for their subscription is in view.
