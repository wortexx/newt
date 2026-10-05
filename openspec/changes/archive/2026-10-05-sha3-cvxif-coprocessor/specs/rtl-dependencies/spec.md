# Spec Delta

## MODIFIED Requirements

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
