# ci-pipeline delta — azure-infra-as-code

## ADDED Requirements

### Requirement: Infrastructure templates are validated on every pull request that touches them

The system SHALL run, on a GitHub-hosted runner, a check that compiles and lints the infrastructure templates on every pull request (and every push to `main`) that changes files under the infrastructure directory. The check SHALL fail on any compile error or lint error. It SHALL NOT authenticate to Azure, SHALL NOT preview or apply deployments, and SHALL NOT require any secret or environment — validation is purely local to the checkout, so the CI identity's scope is never widened for it.

#### Scenario: Template error on a PR

- **WHEN** a pull request changes an infrastructure template so it no longer compiles or fails a lint rule
- **THEN** the check fails and the error is visible in the job log

#### Scenario: Clean template change

- **WHEN** a pull request changes infrastructure templates that compile and lint cleanly
- **THEN** the check exits 0

#### Scenario: PR does not touch infrastructure

- **WHEN** a pull request changes no file under the infrastructure directory
- **THEN** the infrastructure validation check does not run

#### Scenario: No Azure access

- **WHEN** the validation job's configuration is inspected
- **THEN** it declares no Azure login step, no environment, and no OIDC token permission
