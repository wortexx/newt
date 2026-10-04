# Spec Delta

## MODIFIED Requirements

### Requirement: Cheshire is pinned to a released tag with an exact lock
The project SHALL declare its Cheshire dependency by a released upstream version (a tag), or by a commit in a project-owned fork. It SHALL NOT use an untagged upstream commit.

A fork pin SHALL name an annotated tag of the form `v<upstream-version>-newt.<N>`, on a fork branch cut from that upstream release, so the upstream base and the newt revision can both be read from the pin. `Bender.lock` SHALL record the exact commit that the pin resolves to.

As of this change, Cheshire SHALL be declared from the fork `https://github.com/wortexx/cheshire.git` at `rev: v0.3.1-newt.2`. The locked commit SHALL be `e6b9c0dace17b679d24e31a98dc1fb781776b055`, which is upstream v0.3.1 (`5c76406`) plus three commits:
- the `newt.1` address-map fix;
- upstream `71f9cb2` cherry-picked (CVA6 `pulp-v2.0.0`);
- the explicit `ZKN = 0` pin.

#### Scenario: Declared pin resolves to the locked fork commit
- **WHEN** `Bender.yml` and `Bender.lock` are inspected on `main`
- **THEN** `cheshire` is declared from `https://github.com/wortexx/cheshire.git` with `rev: v0.3.1-newt.2`, and the lock entry records revision `e6b9c0dace17b679d24e31a98dc1fb781776b055` with version `0.3.1-newt.2`

#### Scenario: Fork tag sits directly on its upstream base
- **WHEN** the fork tag `v0.3.1-newt.2` is inspected
- **THEN** upstream `v0.3.1` (`5c76406`) is an ancestor of it, and every commit between them is a newt patch or a cherry-picked upstream commit described in the tag message

#### Scenario: CVA6 resolves to the PULP v2 release
- **WHEN** `Bender.lock` is inspected
- **THEN** `cva6` records revision `4c02b24fe7c04690f626776a92274da24f80d1da` (`pulp-v2.0.0`), and `fpnew` records `e5aa6a01b5bbe1675c3aa8872e1203413ded83d1` (`pulp-v0.2.3`)

#### Scenario: Dependency graph resolves cleanly
- **WHEN** `bender sources` runs against the committed `Bender.yml`/`Bender.lock` (as the fast-lane `lint` job does)
- **THEN** it exits 0 without reporting a version conflict

## ADDED Requirements

### Requirement: The declared CVA6 configuration is the built configuration
Every CVA6 parameter the project overrides in `iguana.mk` (`IG_CVA6_CONFIG` and `IG_CVA6_PKG_PARAMS`) SHALL reach the core instantiated in the design. A parameter override that the SoC integration ignores SHALL be treated as a defect, not as a no-op. Any ISA extension the project does not use and that the core makes configurable through a struct field the parameter mechanism cannot reach (currently CV-X-IF and Zkn) SHALL be set explicitly in the project's Cheshire fork, not left to an upstream default.

#### Scenario: Hypervisor extension is off in the built core
- **WHEN** the design is pickled with `IG_CVA6_PKG_PARAMS` containing `CVA6ConfigHExtEn=0`
- **THEN** the CVA6 configuration the core is elaborated with has `RVH = 0`

#### Scenario: Unused extensions are pinned off in the fork
- **WHEN** `cheshire_pkg::gen_cva6_cfg` in the pinned fork is inspected
- **THEN** it assigns `CvxifEn = 0` and `ZKN = 0` explicitly
