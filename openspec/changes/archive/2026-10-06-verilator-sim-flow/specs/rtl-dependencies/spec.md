# rtl-dependencies — verilator-sim-flow

## MODIFIED Requirements

### Requirement: Text-keyed pickle patches match the pinned design
Every pickle-stage sed rule and patch hunk whose target text lies in a dependency SHALL either apply to the pickle produced from the currently pinned dependencies, or be removed. A rule or hunk that no longer matches SHALL NOT be left in the patch set, because the pickle stage tolerates failed hunks and a stale rule is otherwise indistinguishable from a working one.

`wt_axi_adapter2.patch` (CVA6 `wt_axi_adapter.sv`, used by both the pickle and the Verilator lane's file list) is a local backport of upstream CVA6 commit `71f96d43` ("Remove redundant, parameterization-breaking zero extensions", in `pulp-v2.0.0-alpha.1` and later). When CVA6 is pinned at or above that commit, the patch SHALL be deleted, and the Verilator lane SHALL take `wt_axi_adapter.sv` from the dependency tree unmodified.

#### Scenario: Every retained rule changes the pickle
- **WHEN** the pickle stage runs against the Cheshire v0.3.1 dependency tree
- **THEN** every retained sed rule matches at least one line, and every retained patch applies without a rejected hunk

#### Scenario: Obsolete rule is removed, not left dormant
- **WHEN** a rule's target text no longer exists in the pickle because upstream rewrote it (e.g. the CVA6 ID-map `default:` return in `cheshire_pkg`)
- **THEN** the rule is either re-targeted at the new text (if the pickle toolchain still needs it) or deleted from the patch set

#### Scenario: CVA6 upgrade retires the wt_axi_adapter backport
- **WHEN** the resolved CVA6 is `pulp-v2.0.0-alpha.1` or later (it contains `71f96d43`)
- **THEN** `target/ihp13/pickle/patches/morty/wt_axi_adapter2.patch` is removed, along with `verilator.mk`'s patched-copy substitution (`VERILATOR_WT_AXI_*`), and the model still builds under Verilator
