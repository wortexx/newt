## ADDED Requirements

### Requirement: Dependency checkout does not depend on the legacy buildroot git server

Every CI lane that checks out the project's dependencies SHALL fetch the buildroot repository, reached as a nested submodule of Cheshire's `cva6-sdk`, over HTTPS from buildroot's GitLab project, `https://gitlab.com/buildroot.org/buildroot.git`, and SHALL NOT contact `git://git.buildroot.net`. The redirect SHALL apply to every git invocation in the lane, including those made by the dependency manager inside the job container, and SHALL resolve to the same commit the pinned `cva6-sdk` revision records. Transient-fault retries around the dependency checkout SHALL remain in place for the lane's other remotes.

#### Scenario: Legacy buildroot server unreachable

- **WHEN** `git://git.buildroot.net` resets or refuses every connection while a CI lane checks out its dependencies
- **THEN** the checkout still succeeds, with buildroot at the commit pinned by `cva6-sdk`, and the lane proceeds to its own steps

#### Scenario: The redirect reaches nested submodules

- **WHEN** a CI job that checks out dependencies resolves the legacy buildroot URL (`git ls-remote --get-url git://git.buildroot.net/buildroot`), inside its job container where it has one
- **THEN** it resolves to `https://gitlab.com/buildroot.org/buildroot.git`, and the job fails before its dependency checkout if it does not
