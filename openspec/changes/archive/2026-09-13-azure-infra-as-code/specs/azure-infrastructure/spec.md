# azure-infrastructure — azure-infra-as-code

## Purpose

Defines what the project's Azure footprint for CI must satisfy: every resource the CI lanes depend on is declared in versioned templates and deployed idempotently behind a preview gate, the self-hosted runner host can be rebuilt from the repository alone, credentials stay where they belong, and cost and ingress guardrails are declared rather than remembered.

## ADDED Requirements

### Requirement: Every CI Azure resource is declared in versioned templates

The system SHALL declare, in infrastructure templates committed to the repository, every Azure resource the CI lanes depend on: the runner VM with its network interface, virtual network, public IP and network security group; the CI managed identity with its GitHub OIDC federated credential; the CI identity's role assignments; the checkpoint storage account with its container and lifecycle rule; the Key Vault used for runner registration and the VM identity's access to it; and the cost budget. The templates SHALL be the source of truth for these resources' configuration. The one documented exception is the pre-existing fixed-time auto-shutdown schedule, which is left undeclared until `docs/infra-plan.md` Phase 9 deletes it.

#### Scenario: Live resource group matches the templates

- **WHEN** the resources in the CI resource group are listed and compared against the templates
- **THEN** every resource except the documented auto-shutdown exception corresponds to a declared resource, and any undeclared resource is reported as drift

#### Scenario: Configuration change goes through the templates

- **WHEN** a property of a declared resource (for example the SSH source range or the budget amount) needs to change
- **THEN** the change is made in the committed templates and deployed from them, not applied by hand to the live resource

### Requirement: Deployment is idempotent and previewed before it is applied

Deploying the templates against the live resource group SHALL be idempotent: deploying an unchanged template SHALL produce no resource-level changes. Before any deployment is applied to the live resource group, a preview of the changes SHALL be produced, and the deployment SHALL NOT be applied if the preview shows any resource being deleted or replaced.

Property-level differences on read-only, provider-computed properties are exempt: the preview reports them on every run because they are returned by the provider but cannot be expressed in a template, and applying the deployment does not change them. They SHALL be documented where they occur rather than treated as drift or as grounds to leave a resource undeclared.

#### Scenario: Unchanged template redeployed

- **WHEN** the templates are deployed a second time with no edits since the previous deployment
- **THEN** the preview reports no resource-level changes and the deployment completes without modifying any resource

#### Scenario: Preview reports a read-only property it cannot declare

- **WHEN** the preview reports a property-level difference on a property the provider computes and the template language cannot express
- **THEN** the resource stays declared, the difference is recorded as a known exception, and it does not block applying the deployment

#### Scenario: Preview shows a destructive change

- **WHEN** the preview of a deployment reports a resource would be deleted or replaced
- **THEN** the deployment is not applied until the templates are corrected so the preview no longer shows that change

#### Scenario: Existing resources are adopted, not recreated

- **WHEN** the templates are deployed for the first time against the resource group that already holds the hand-built resources
- **THEN** the VM, its OS disk, network resources, identity, federated credential, storage account and container keep their names and contents, and the runner registration and caches on the OS disk survive

### Requirement: Runner host is reproducible from the repository

The system SHALL provide, in the repository, a host provisioning definition that brings a freshly created VM to the state the CI lanes require without manual steps beyond supplying the registration credential: container runtime installed and usable by the runner user; Azure CLI installed; the GitHub Actions runner installed as a system service that reconnects on boot, registered with the runner name and labels the lanes target; automatic package upgrades disabled; and the service-restart override that protects the runner and container runtime from being restarted underneath a live job. The provisioning definition SHALL be idempotent so it can also be applied to an already-provisioned host.

#### Scenario: Fresh VM provisioned from the template

- **WHEN** a VM is created from the templates with the provisioning definition and allowed to finish first boot
- **THEN** a runner with the expected name and labels reports online in the repository's runner list, a container image can be pulled and run as the runner user, the Azure CLI responds to a version query, the automatic upgrade timer is disabled, and the restart override file is present

#### Scenario: Provisioning re-applied to a provisioned host

- **WHEN** the provisioning definition is re-run on a host that already satisfies it
- **THEN** it exits successfully, changes nothing, and the existing runner registration and service remain intact and online

#### Scenario: Existing hand-built VM converged

- **WHEN** the provisioning definition is applied to the existing hand-built runner VM
- **THEN** it completes without re-registering the runner or disturbing the caches on the OS disk, and the host state afterwards matches what a fresh VM would have

### Requirement: Runner registration uses a credential held only in Key Vault

The GitHub credential used to mint runner registration tokens SHALL be stored only as a secret in the declared Key Vault, readable solely by the VM's own managed identity. It SHALL NOT appear in the repository, in template parameter files, in GitHub repository secrets or variables, in workflow logs, or on the VM's disk after registration. Rotating the credential SHALL require only updating the Key Vault secret and re-running provisioning.

#### Scenario: Fresh VM registers itself

- **WHEN** a freshly provisioned VM runs registration
- **THEN** it obtains the credential from Key Vault via its own managed identity, exchanges it for a short-lived registration token, registers the runner, and leaves no copy of the credential on disk

#### Scenario: Credential is absent from the repository and GitHub settings

- **WHEN** the repository contents, the template parameter file, and the repository's GitHub secrets and variables are inspected
- **THEN** none of them contain the registration credential

#### Scenario: Credential rotated

- **WHEN** the Key Vault secret is replaced with a new credential and provisioning is re-run
- **THEN** subsequent registrations use the new credential and no template or workflow edit was needed

### Requirement: CI identity scope stays bounded

The CI managed identity used by the workflows SHALL hold exactly the role assignments the lanes need — Virtual Machine Contributor scoped to the runner VM and Storage Blob Data Contributor scoped to the checkpoint container — and SHALL NOT be granted access to the Key Vault, the resource group, or the subscription. Deploying the templates SHALL NOT widen this scope.

#### Scenario: Role assignments after deployment

- **WHEN** the CI identity's role assignments are listed after the templates have been deployed
- **THEN** they consist of exactly the two assignments above, at exactly those scopes

#### Scenario: CI identity cannot read the registration credential

- **WHEN** the CI identity attempts to read the Key Vault secret
- **THEN** the request is denied

#### Scenario: Workflows keep working after adoption

- **WHEN** a lane workflow authenticates via OIDC after the templates have been deployed
- **THEN** VM start/deallocate and checkpoint upload/download succeed exactly as before

### Requirement: Cost and ingress guardrails are declared

The templates SHALL declare a monthly cost budget on the CI resource group with e-mail notifications at increasing thresholds of actual spend, with the amount and recipient as parameters. The templates SHALL restrict inbound SSH to a single parameterised source address range and SHALL declare no other inbound allow rule.

#### Scenario: Budget threshold crossed

- **WHEN** actual spend in the resource group crosses a declared threshold within a month
- **THEN** a notification is sent to the configured recipient

#### Scenario: Network security group rules

- **WHEN** the runner VM's network security group rules are inspected after deployment
- **THEN** the only inbound allow rule permits port 22 from the parameterised source range, and no unscoped allow rule exists
