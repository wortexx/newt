// Copyright 2026 the newt project authors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The CI lanes' Azure footprint - docs/infra-plan.md Phase 6.
//
// Declares the resource graph that synth.yml, pnr.yml and vm-watchdog.yml
// depend on. Every name here matches what those workflows hardcode; renaming
// anything breaks them (design D2). Deployed incrementally, always previewed
// with `az deployment group what-if` first - see README.md.
//
// The undeclared-on-purpose exception is the DevTestLab auto-shutdown
// schedule `shutdown-computevm-newt-synth-runner`, which incremental mode
// leaves alone until infra-plan Phase 9 deletes it.

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Region for every resource. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('Runner VM name. Also the stem for its network resource names.')
param vmName string = 'newt-synth-runner'

@description('VM size. Standard_E16ds_v5 is 16 vCPU / 128 GB - the synth and P&R requirement.')
param vmSize string = 'Standard_E16ds_v5'

@description('Admin user on the VM. The Actions runner service also runs as this user.')
param adminUsername string = 'newt'

@description('SSH public key for the admin user. Public by definition; safe to commit.')
param adminPublicKey string

@description('The only CIDR allowed inbound on port 22.')
param sshSourceAddressPrefix string

@description('OS disk name. Empty means derive it from vmName - set it explicitly to adopt an existing disk.')
param osDiskName string = ''

@description('OS disk size in GB. 0 omits the property, which is required when adopting an existing VM - ARM does not store it on the VM and rejects adding it.')
param osDiskSizeGb int = 128

@description('VNet address space.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Runner subnet address range.')
param subnetAddressPrefix string = '10.0.0.0/24'

@description('User-assigned identity the workflows authenticate as over OIDC.')
param ciIdentityName string = 'newt-ci-identity'

@description('GitHub owner login, for the federated credential subject.')
param githubOwner string = 'wortexx'

@description('GitHub numeric owner ID. This repo presents ID-embedded OIDC subjects (ci-pnr-lane D8).')
param githubOwnerId string

@description('GitHub repository name, for the federated credential subject.')
param githubRepo string = 'newt'

@description('GitHub numeric repository ID.')
param githubRepoId string

@description('GitHub Actions environment named in the federated credential subject.')
param githubEnvironment string = 'azure'

@description('Checkpoint storage account name.')
param storageAccountName string = 'newtpnrcheckpoints'

@description('Blob container pnr.yml uploads checkpoints to.')
param containerName string = 'pnr-checkpoints'

@description('Days after which a checkpoint blob is deleted.')
param checkpointRetentionDays int = 30

@description('Key Vault holding github-runner-pat. Globally unique.')
param keyVaultName string

@description('Resource group holding the Key Vault. Defaults to this one; the rehearsal points at the real vault.')
param keyVaultResourceGroupName string = resourceGroup().name

@description('Monthly budget in USD.')
param budgetAmount int = 150

@description('Budget notification recipient.')
param budgetContactEmail string

@description('Budget start date, yyyy-MM-01. Must be the first of a month and not in a closed period.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Budget end date, yyyy-MM-01. Declared explicitly because ARM otherwise defaults it to start+10y and the preview then reports a delete every run.')
param budgetEndDate string = '2036-09-01'

@description('Actions runner name registered with GitHub. Empty skips registration.')
param runnerName string = 'newt-synth-runner'

@description('Comma-separated runner labels the lanes target.')
param runnerLabels string = 'self-hosted-synth'

@description('Attach cloud-init as customData. Only honoured on a VM first boot, so leave false when adopting.')
param provisionOnFirstBoot bool = false

@description('VM securityType. Leave empty in both directions unless you know otherwise: ARM rejects adding it to an existing VM, and rejects the value Standard on a new one unless the preview feature Microsoft.Compute/UseStandardSecurityType is registered. Empty means a fresh Gen2 VM gets the Azure default, TrustedLaunch.')
param securityType string = ''

@description('Deploy the CI identity, its federated credential and its two role assignments.')
param deployCiIdentity bool = true

@description('Deploy the checkpoint storage account, container and lifecycle rule.')
param deployStorage bool = true

@description('Deploy the Key Vault. False points the VM at an existing vault instead.')
param deployKeyVault bool = true

@description('Deploy the resource-group monthly budget.')
param deployBudget bool = true

@description('AAD object ID of the human operator who sets and rotates the runner PAT. Empty grants nobody. Supplied from the environment at deploy time rather than committed, since it names a person - see README.')
param keyVaultAdminPrincipalId string = ''

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var subnetName = '${vmName}Subnet'
var osDiskNameActual = empty(osDiskName) ? '${vmName}_OsDisk' : osDiskName

// Built-in role definition IDs (stable across tenants).
var vmContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
var blobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var keyVaultSecretsOfficerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

// cloud-init carries provision-runner.sh base64-encoded so the script stays a
// single source of truth: one file, three entry points (first boot, run-command,
// by hand). See design D3 and cloud-init.yaml.
var provisionScript = loadTextContent('provision-runner.sh')
var cloudInitRendered = replace(replace(replace(replace(replace(
  loadTextContent('cloud-init.yaml'),
  '__PROVISION_SCRIPT_B64__', base64(provisionScript)),
  '__KEY_VAULT_NAME__', keyVaultName),
  '__RUNNER_NAME__', runnerName),
  '__RUNNER_LABELS__', runnerLabels),
  '__GITHUB_REPO__', '${githubOwner}/${githubRepo}')

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${vmName}NSG'
  location: location
  properties: {
    securityRules: [
      {
        // The only inbound allow rule. `az vm create` once added an unscoped
        // default-allow-ssh here; declaring the full rule list keeps it gone.
        name: 'AllowSSHFromMe'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${vmName}VNET'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    // Declared at its live value; omitting it makes what-if predict a delete.
    privateEndpointVNetPolicies: 'Disabled'
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${vmName}PublicIP'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
    // ARM populates this on write; declaring it keeps previews clean.
    ddosSettings: {
      protectionMode: 'VirtualNetworkInherited'
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}VMNic'
  location: location
  properties: {
    enableAcceleratedNetworking: false
    enableIPForwarding: false
    disableTcpStateTracking: false
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
    nicType: 'Standard'
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig${vmName}'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetName)
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Runner VM
// ---------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  // The VM reads github-runner-pat from Key Vault as itself; newt-ci-identity
  // deliberately gets no vault access (design D4).
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        // `latest` matches the live VM; its resolved exactVersion is not
        // declared, so image refreshes never show up as a Replace.
        version: 'latest'
      }
      osDisk: union({
        // FromImage plus the live disk name is the adoption path that leaves
        // the runner registration, Docker cache and synth cache untouched.
        name: osDiskNameActual
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Detach'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }, osDiskSizeGb == 0 ? {} : { diskSizeGB: osDiskSizeGb })
    }
    osProfile: union({
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'ImageDefault'
          assessmentMode: 'ImageDefault'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }, provisionOnFirstBoot ? { customData: base64(cloudInitRendered) } : {})
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  // securityProfile is omitted unless asked for: the live VM was created
  // without a stored securityType, and ARM rejects adding one to an existing
  // VM with PropertyChangeNotAllowed even when the value matches what GET
  // reports ('Standard'). A fresh build passes securityType=Standard.
  }, empty(securityType) ? {} : { securityProfile: { securityType: securityType } })
}

// ---------------------------------------------------------------------------
// CI identity (OIDC) and its two role assignments
// ---------------------------------------------------------------------------

resource ciIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployCiIdentity) {
  name: ciIdentityName
  location: location
}

resource ciFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = if (deployCiIdentity) {
  parent: ciIdentity
  name: 'gh-actions-azure-env'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    // ID-embedded subject: this repo presents immutable OIDC subject claims,
    // so the plain-name form does not match (ci-pnr-lane D8).
    subject: 'repo:${githubOwner}@${githubOwnerId}/${githubRepo}@${githubRepoId}:environment:${githubEnvironment}'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}

resource vmContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployCiIdentity) {
  scope: vm
  name: guid(vm.id, ciIdentity.id, vmContributorRoleId)
  properties: {
    roleDefinitionId: vmContributorRoleId
    principalId: ciIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployCiIdentity && deployStorage) {
  scope: checkpointContainer
  name: guid(checkpointContainer.id, ciIdentity.id, blobDataContributorRoleId)
  properties: {
    roleDefinitionId: blobDataContributorRoleId
    principalId: ciIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Checkpoint storage
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = if (deployStorage) {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    allowCrossTenantReplication: false
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
  }
}

// Referenced, never written: the container needs a parent, but a PUT here with
// no properties would be predicted to wipe the account cors and retention settings.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource checkpointContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (deployStorage) {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
  }
}

resource checkpointLifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = if (deployStorage) {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-${containerName}-after-${checkpointRetentionDays}-days'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ '${containerName}/' ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: checkpointRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Key Vault for the runner-registration PAT
// ---------------------------------------------------------------------------

// The github-runner-pat secret itself is set by hand and never declared -
// declaring it would put the value in a parameter or the deployment history.
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    // One secret, read by one VM identity. A private endpoint would mean VNet
    // plumbing this does not justify (design Non-Goals).
    publicNetworkAccess: 'Enabled'
  }
}

// Scoped through a module so the rehearsal deployment (design D8), which runs
// in a scratch resource group, can still grant its VM access to the real vault.
module vaultSecretsUser 'modules/keyvault-secrets-user.bicep' = {
  name: 'kv-secrets-user-${vmName}'
  scope: resourceGroup(keyVaultResourceGroupName)
  params: {
    keyVaultName: keyVaultName
    principalId: vm.identity.principalId
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
  dependsOn: [ keyVault ]
}

// The human who sets and rotates github-runner-pat. Needed because the vault is
// RBAC-authorised: subscription Owner confers no data-plane access, so without
// this `az keyvault secret set` fails with Forbidden. There is no set-only
// role, so this principal can also read the secret - it is the operator, not a
// workload, and the CI identity still gets nothing.
module vaultSecretsOfficer 'modules/keyvault-secrets-user.bicep' = if (!empty(keyVaultAdminPrincipalId)) {
  name: 'kv-secrets-officer'
  scope: resourceGroup(keyVaultResourceGroupName)
  params: {
    keyVaultName: keyVaultName
    principalId: keyVaultAdminPrincipalId
    roleDefinitionId: keyVaultSecretsOfficerRoleId
    principalType: 'User'
  }
  dependsOn: [ keyVault ]
}

// ---------------------------------------------------------------------------
// Cost guardrail
// ---------------------------------------------------------------------------

// A notification, not an enforcement - vm-watchdog.yml is the backstop that
// actually stops spend (design D5).
resource budget 'Microsoft.Consumption/budgets@2023-05-01' = if (deployBudget) {
  name: 'budget-${resourceGroup().name}-monthly'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      // ARM stores and returns full ISO timestamps; sending a bare date makes
      // every preview report a modify.
      startDate: '${budgetStartDate}T00:00:00Z'
      endDate: '${budgetEndDate}T00:00:00Z'
    }
    notifications: {
      actual50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [ budgetContactEmail ]
      }
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [ budgetContactEmail ]
      }
      actual100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [ budgetContactEmail ]
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output vmPrincipalId string = vm.identity.principalId
output ciIdentityClientId string = deployCiIdentity ? ciIdentity!.properties.clientId : ''
output ciIdentityPrincipalId string = deployCiIdentity ? ciIdentity!.properties.principalId : ''
output publicIpAddress string = publicIp.properties.ipAddress
output keyVaultUri string = deployKeyVault ? keyVault!.properties.vaultUri : ''

param deliberatelyUnused string = 'boom'
