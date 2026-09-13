# azure-infrastructure — post-merge-ci-verification

## MODIFIED Requirements

### Requirement: Every CI Azure resource is declared in versioned templates

The system SHALL declare, in infrastructure templates committed to the repository, every Azure resource the CI lanes depend on: the runner VM with its network interface, virtual network, public IP and network security group; the CI managed identity with its GitHub OIDC federated credential; the CI identity's role assignments; the checkpoint storage account with its container and lifecycle rule; the Key Vault used for runner registration and the VM identity's access to it; and the cost budget. The templates SHALL be the source of truth for these resources' configuration. No fixed-time auto-shutdown schedule SHALL exist on the runner VM: the idle-VM watchdog and the P&R lane's own stop step are the only automatic deallocation mechanisms, and neither is an Azure resource.

#### Scenario: Live resource group matches the templates

- **WHEN** the resources in the CI resource group are listed and compared against the templates
- **THEN** every resource corresponds to a declared resource, and any undeclared resource is reported as drift

#### Scenario: No fixed-time shutdown schedule remains

- **WHEN** the CI resource group is listed after the auto-shutdown schedule has been deleted
- **THEN** no `Microsoft.DevTestLab/schedules` resource exists in the group, and the runner VM's instance view reports no auto-shutdown

#### Scenario: Configuration change goes through the templates

- **WHEN** a property of a declared resource (for example the SSH source range or the budget amount) needs to change
- **THEN** the change is made in the committed templates and deployed from them, not applied by hand to the live resource
