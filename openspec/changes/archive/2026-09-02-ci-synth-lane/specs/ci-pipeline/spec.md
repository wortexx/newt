## ADDED Requirements

### Requirement: Synth lane runs on a schedule and on demand, not per-PR

The system SHALL provide a full-synthesis CI lane, in a workflow separate from the per-PR fast lane, that runs on: a nightly schedule against `main`, a manual `workflow_dispatch`, and pull requests carrying the `full-synth` label (including re-runs on subsequent pushes to a PR while the label is present). It SHALL NOT run on unlabeled pushes or pull requests.

#### Scenario: Nightly run

- **WHEN** the scheduled trigger fires
- **THEN** the synth lane runs once against the current `main`

#### Scenario: Manual dispatch

- **WHEN** a user triggers the workflow via `workflow_dispatch`
- **THEN** the synth lane runs against the selected ref

#### Scenario: PR labeled full-synth

- **WHEN** the `full-synth` label is added to an open pull request, or a commit is pushed to a PR that already carries the label
- **THEN** the synth lane runs against that PR's head and reports its status on the PR

#### Scenario: Ordinary PR without the label

- **WHEN** a pull request without the `full-synth` label is opened or updated
- **THEN** the synth lane does not run for it

### Requirement: Synth lane never auto-executes a fork pull request's code

Because the synth lane runs on a self-hosted runner, the system SHALL NOT automatically run the synth lane against a pull request whose head branch is not part of the `wortexx/newt` repository itself, even when that pull request carries the `full-synth` label. Such a run SHALL require explicit maintainer approval before it executes.

#### Scenario: Same-repo branch carries the label

- **WHEN** a pull request from a branch of `wortexx/newt` itself carries the `full-synth` label
- **THEN** the synth lane runs automatically, per the labeled-PR requirement above

#### Scenario: Fork pull request carries the label

- **WHEN** a pull request from a fork carries the `full-synth` label
- **THEN** the synth lane does not run automatically against it; it runs only after a maintainer explicitly approves that run

### Requirement: Synth lane runs the full pickle-to-netlist flow

The synth lane SHALL run the complete hardware-generation, pickling, and monolithic yosys synthesis flow (`ig-hw-all`, then `pickle-all`, then `synth-all`) inside the `newt-eda` container, regenerating all flow inputs (including the bender sources manifest) in-container from a fresh checkout. It SHALL use the monolithic synthesis path, not the hierarchical one (known broken on this design).

#### Scenario: Flow runs end to end

- **WHEN** the synth lane runs on a revision where the flow is healthy
- **THEN** pickling and synthesis complete and a technology-mapped netlist is produced

#### Scenario: Pickle is never stale

- **WHEN** the synth lane runs on a revision that changed RTL since the last run
- **THEN** the synthesized netlist reflects that revision's RTL (pickling ran in the same job; no checkpoint or manifest from an earlier run or the developer's host is reused)

### Requirement: Synth lane publishes netlist and reports as artifacts

The synth lane SHALL upload the synthesized netlist and the synthesis report directory as workflow artifacts with a bounded retention period, so a run's outputs can be inspected and compared without re-running the ~3 h flow.

#### Scenario: Successful run uploads outputs

- **WHEN** a synth-lane run completes synthesis
- **THEN** the netlist and the report files are downloadable as artifacts of that run

#### Scenario: Failed run still uploads what exists

- **WHEN** a synth-lane run fails after producing logs or partial reports
- **THEN** whatever reports and logs exist are still uploaded to aid diagnosis

### Requirement: Synth lane posts a metrics summary compared against a checked-in baseline

The synth lane SHALL extract cell count, chip area, and DFF count from the synthesis reports, and WNS from a static-timing run of the produced netlist, and SHALL post them in the run's summary alongside each metric's delta versus a baseline file checked into the repository. The baseline SHALL only change via a deliberate commit (seeded from the Phase 1 adoption-gate reference run), never automatically from a CI run.

#### Scenario: Summary on a successful run

- **WHEN** a synth-lane run completes synthesis and timing analysis
- **THEN** the run summary shows cell count, chip area, DFF count, and WNS, each with its absolute value and delta vs the checked-in baseline

#### Scenario: Baseline is stable across runs

- **WHEN** two synth-lane runs execute against the same revision
- **THEN** both compare against the same checked-in baseline values; neither run rewrites the baseline

### Requirement: Synth lane fails only on flow failure or design-check problems, and never gates merges

The synth lane SHALL exit non-zero when any flow stage fails or when the yosys `CHECK` report contains one or more problems. It SHALL NOT fail because a metric drifted from the baseline (drift is reported in the summary only), and its job SHALL NOT be added to `main`'s required status checks.

#### Scenario: Yosys CHECK reports a problem

- **WHEN** synthesis completes but the `CHECK` report contains at least one problem
- **THEN** the synth-lane job exits non-zero

#### Scenario: Metrics drift but flow is clean

- **WHEN** synthesis completes with 0 `CHECK` problems and a metric differs from the baseline
- **THEN** the job exits 0 and the summary shows the drift

#### Scenario: Synth lane is not a required check

- **WHEN** `main`'s branch protection required-status-checks list is inspected
- **THEN** the synth-lane job name does not appear in it
