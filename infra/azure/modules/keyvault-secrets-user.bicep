// Copyright 2026 the newt project authors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Grants one principal one Key Vault role on one vault.
//
// This exists as a module purely for scope: a role assignment must be created
// in the resource group that holds its scope, and the fresh-build rehearsal
// (design D8) deploys a scratch VM into its own resource group while pointing
// at the real vault. main.bicep deploys this module into the vault's group.

targetScope = 'resourceGroup'

@description('Vault to grant access on. Must already exist in this resource group.')
param keyVaultName string

@description('Principal receiving the role - the VM system-assigned identity.')
param principalId string

@description('Fully qualified role definition ID to assign.')
param roleDefinitionId string

@description('Principal type. ServicePrincipal for managed identities, User for a human operator.')
@allowed([ 'ServicePrincipal', 'User', 'Group' ])
param principalType string = 'ServicePrincipal'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: principalType
  }
}
