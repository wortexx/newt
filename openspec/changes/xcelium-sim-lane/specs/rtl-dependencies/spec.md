# rtl-dependencies Specification (delta)

## MODIFIED Requirements

### Requirement: Cheshire is pinned to a released tag with an exact lock
The project SHALL declare its Cheshire dependency by a released upstream version (a tag), or by a commit in a project-owned fork. It SHALL NOT use an untagged upstream commit.

A fork pin SHALL name an annotated tag of the form `v<upstream-version>-newt.<N>`, on a fork branch cut from that upstream release, so the upstream base and the newt revision can both be read from the pin. `Bender.lock` SHALL record the exact commit that the pin resolves to.

As of this change, Cheshire SHALL be declared from the fork `https://github.com/wortexx/cheshire.git` at `rev: v0.3.1-newt.1`, and the locked commit SHALL be `465e9e8aafee428642778c39e9f40b6b2452df5f`, which is upstream v0.3.1 (`5c76406`) plus one commit.

#### Scenario: Declared pin resolves to the locked fork commit
- **WHEN** `Bender.yml` and `Bender.lock` are inspected on `main`
- **THEN** `cheshire` is declared from `https://github.com/wortexx/cheshire.git` with `rev: v0.3.1-newt.1`, and the lock entry records revision `465e9e8aafee428642778c39e9f40b6b2452df5f` with version `0.3.1-newt.1`

#### Scenario: Fork tag sits directly on its upstream base
- **WHEN** the fork tag `v0.3.1-newt.1` is inspected
- **THEN** upstream `v0.3.1` (`5c76406`) is an ancestor of it, and every commit between them is a newt patch described in the tag message

#### Scenario: Dependency graph resolves cleanly
- **WHEN** `bender sources` runs against the committed `Bender.yml`/`Bender.lock` (as the fast-lane `lint` job does)
- **THEN** it exits 0 without reporting a version conflict
