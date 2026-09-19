# ci-pipeline delta — upgrade-github-actions

## ADDED Requirements

### Requirement: Third-party actions are referenced by immutable commit SHA

Every workflow step that uses an action published outside the `actions/` organization SHALL reference it by a full 40-character commit SHA, not by a branch, a floating major tag, or a release tag. Each such reference SHALL carry a trailing comment naming the human-readable version the SHA corresponds to, so the intended version stays legible in review. Actions published by GitHub under `actions/` MAY be referenced by major tag, as GitHub controls that namespace and the repository's threat model treats it as trusted.

This exists because a mutable tag can be repointed by a compromised or careless upstream without any change in this repository, silently altering what executes on runners that hold Azure OIDC federation and registry write credentials.

#### Scenario: Workflow adds a third-party action

- **WHEN** a workflow step is added or edited to use an action outside the `actions/` organization
- **THEN** its `uses:` value is a 40-character commit SHA with a trailing version comment, and a tag-only reference is treated as a defect

#### Scenario: Third-party action is upgraded

- **WHEN** a third-party action is moved to a newer release
- **THEN** both the pinned SHA and its trailing version comment are updated together, so the comment never names a version the SHA does not point at

#### Scenario: First-party action reference

- **WHEN** a workflow step uses an action under the `actions/` organization
- **THEN** a major-tag reference such as `actions/checkout@v7` satisfies this requirement

### Requirement: Action dependencies are watched for new releases

The repository SHALL configure automated dependency updates for the `github-actions` ecosystem covering `.github/workflows/`, such that a new release of any action referenced there surfaces as a pull request against this repository without human polling. Those pull requests SHALL be subject to the same required status checks as any other pull request, and SHALL NOT be merged automatically.

This exists because the pipeline's action dependencies previously drifted three major versions behind unnoticed; nothing in the repository was watching them.

#### Scenario: Upstream publishes a new action release

- **WHEN** an action referenced by a workflow publishes a new release
- **THEN** a pull request proposing the updated reference appears on this repository without anyone checking upstream manually

#### Scenario: Update pull request runs CI

- **WHEN** such a pull request is opened
- **THEN** the standard pull-request lane runs against it and its result gates the merge exactly as for a human-authored pull request

#### Scenario: SHA-pinned action is updated

- **WHEN** the update targets a third-party action pinned by commit SHA
- **THEN** the proposed change updates the SHA and its version comment together, preserving the pinning requirement above

### Requirement: Workflows run only on action releases their runners support

Every action reference used by a workflow SHALL be a release whose required runtime is supported by every runner that workflow can execute on, including the self-hosted runner used by the synth and P&R lanes. A runner that cannot satisfy a referenced action's runtime floor SHALL be brought up to a supporting version before that reference lands on a lane targeting it.

This exists because the self-hosted runner's lifecycle is independent of this repository — it is deallocated between runs and updates on its own schedule — so an action release the hosted runners support is not automatically one the self-hosted runner supports.

#### Scenario: Action requires a newer runner than the self-hosted lane provides

- **WHEN** an action reference on a self-hosted lane requires a runner version newer than the one installed on that runner
- **THEN** the mismatch is resolved by updating the runner before the reference is relied on, and the lane is not left referencing an action its runner cannot execute

#### Scenario: Self-hosted lane runs after an action upgrade

- **WHEN** the synth or P&R lane next executes following an action version change
- **THEN** its steps start and run to their normal outcome rather than failing on an unsupported action runtime
