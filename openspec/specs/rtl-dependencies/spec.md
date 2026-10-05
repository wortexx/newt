# rtl-dependencies Specification

## Purpose

Defines how the project pins the upstream RTL IP it builds on (Cheshire and its transitive dependencies), and what must still hold after a pin moves. Flow artifacts that key on a dependency's internal text or hierarchy must keep matching the design they were written for.

## Requirements

### Requirement: Cheshire is pinned to a released tag with an exact lock
The project SHALL declare its Cheshire dependency by a released upstream version (a tag), or by a commit in a project-owned fork. It SHALL NOT use an untagged upstream commit.

A fork pin SHALL name an annotated tag of the form `v<upstream-version>-newt.<N>`, on a fork branch cut from that upstream release, so the upstream base and the newt revision can both be read from the pin. `Bender.lock` SHALL record the exact commit that the pin resolves to.

As of this change, Cheshire SHALL be declared from the fork `https://github.com/wortexx/cheshire.git` at `rev: v0.3.1-newt.2`, and the locked commit SHALL be the commit that tag resolves to. `v0.3.1-newt.2` SHALL descend from `v0.3.1-newt.1` (`465e9e8aafee428642778c39e9f40b6b2452df5f`), and the commits it adds SHALL be limited to exposing core 0's CV-X-IF request/response port at the `cheshire_soc` boundary and to adding the `cheshire_cfg_t` field `Cva6CvxifEn` that enables it. With `Cva6CvxifEn = 0` (the `DefaultCfg` value) and the port left unconnected, the SoC SHALL behave as under `v0.3.1-newt.1`.

#### Scenario: Declared pin resolves to the locked fork commit
- **WHEN** `Bender.yml` and `Bender.lock` are inspected on `main`
- **THEN** `cheshire` is declared from `https://github.com/wortexx/cheshire.git` with `rev: v0.3.1-newt.2`, and the lock entry records the commit `v0.3.1-newt.2` resolves to, with version `0.3.1-newt.2`

#### Scenario: Fork tag sits directly on its upstream base
- **WHEN** the fork tag `v0.3.1-newt.2` is inspected
- **THEN** upstream `v0.3.1` (`5c76406`) and `v0.3.1-newt.1` (`465e9e8`) are both ancestors of it, and every commit after upstream `v0.3.1` is a newt patch described in the tag message

#### Scenario: Default configuration reproduces the previous tie-off
- **WHEN** `cheshire_soc` from `v0.3.1-newt.2` is instantiated with `Cva6CvxifEn = 0` and its new CV-X-IF ports left unconnected (response tied to zero)
- **THEN** CVA6 is configured with `CvxifEn = 0` and receives the same tied-off CV-X-IF response as under `v0.3.1-newt.1`

#### Scenario: Config field enables the core's CV-X-IF
- **WHEN** a configuration sets `Cva6CvxifEn = 1`
- **THEN** core 0 is elaborated with `CvxifEn = 1` and its CV-X-IF request/response are the `cheshire_soc` `cvxif_req_o`/`cvxif_resp_i` ports

#### Scenario: Dependency graph resolves cleanly
- **WHEN** `bender sources` runs against the committed `Bender.yml`/`Bender.lock` (as the fast-lane `lint` job does)
- **THEN** it exits 0 without reporting a version conflict

### Requirement: Root pins do not sit below a dependency's own floor unless deliberately held
For every package that the project declares directly and that Cheshire also declares, the project's declared version SHALL be at least the version Cheshire declares. This way the root `Bender.yml` never states a floor that the resolved graph silently overrides.

The one exception is a deliberate hold, where the project pins a package below Cheshire's declaration because the newer version breaks a flow stage. A hold SHALL be declared at the root with an adjacent comment that states the reason. The held package's external interface, as instantiated by Cheshire, SHALL be identical between the held and the declared versions.

#### Scenario: Shared packages are at or above Cheshire's declaration
- **WHEN** the project's direct `axi` and `register_interface` declarations are compared with Cheshire v0.3.1's `Bender.yml`
- **THEN** each project declaration is at or above Cheshire's (`axi` ≥ 0.39.6, `register_interface` ≥ 0.4.5)

#### Scenario: apb_uart is a documented hold
- **WHEN** the project's direct `apb_uart` declaration (0.2.1) is compared with Cheshire v0.3.1's (0.2.3)
- **THEN** `Bender.yml` carries a comment next to it stating the reason (0.2.3's OBI UART is not readable by the synthesis frontend), `Bender.lock` locks apb_uart 0.2.1, and the `reg_uart_wrap` module interface Cheshire instantiates is identical in 0.2.1 and 0.2.3

### Requirement: Dependency-keyed flow selectors match the pinned design
Every synthesis keep-hierarchy instance selector that names an instance inside a dependency SHALL match at least one instance in the design built from the currently pinned dependencies. A selector that matches nothing SHALL be treated as a defect, not as a no-op.

#### Scenario: DMA keep-hierarchy selector matches after the bump
- **WHEN** the design is elaborated from Cheshire v0.3.1 with the project's `CheshireCfg` (DMA enabled)
- **THEN** the DMA keep-hierarchy selector matches the `cheshire_idma_wrap` instance, and no keep-hierarchy selector list entry resolves to zero instances

### Requirement: Text-keyed pickle patches match the pinned design
Every pickle-stage sed rule and patch hunk whose target text lies in a dependency SHALL either apply to the pickle produced from the currently pinned dependencies, or be removed. A rule or hunk that no longer matches SHALL NOT be left in the patch set, because the pickle stage tolerates failed hunks and a stale rule is otherwise indistinguishable from a working one.

#### Scenario: Every retained rule changes the pickle
- **WHEN** the pickle stage runs against the Cheshire v0.3.1 dependency tree
- **THEN** every retained sed rule matches at least one line, and every retained patch applies without a rejected hunk

#### Scenario: Obsolete rule is removed, not left dormant
- **WHEN** a rule's target text no longer exists in the pickle because upstream rewrote it (e.g. the CVA6 ID-map `default:` return in `cheshire_pkg`)
- **THEN** the rule is either re-targeted at the new text (if the pickle toolchain still needs it) or deleted from the patch set
