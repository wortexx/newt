// Copyright 2026 the newt project authors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Parameters for the live CI resource group, newt-synth-lane-rg.
//
// Every value here is non-secret by design (design D7): the SSH key is a
// public key, the source CIDR and the GitHub numeric IDs are already in this
// repository's history, and the contact address is the commit author address.
// There is no @secure() parameter, so a deployment never prompts for a value -
// the runner PAT is the only secret and lives solely in Key Vault (design D4).

using 'main.bicep'

// --- runner VM (adopts the live resources; names must not change) -----------
param vmName = 'newt-synth-runner'
param vmSize = 'Standard_E16ds_v5'
param adminUsername = 'newt'
// Trailing \n is significant: it is part of the stored value, and ARM rejects
// any difference with PropertyChangeNotAllowed.
param adminPublicKey = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC6U5Rn8eDanhL3qvkXVRQkOucfTyEsPy0pH2TniRrTtJdqS/KeWhOCdZFWn0rcg2ogQVMrRbY7cKT+mkohfbMNyHU95m3Mhinknmf5ptYJljgWCEgbkKeD9ZJXRNbQ1Tg22n4m7xCfNjcplM7MT7RdAZKfO0YMIw2QlgZZ6JM67g42GToIRjbeZjzjWMfNDIrQp9yXb5Cc8BvCmghAd0zjWfeCZKY0pe57jLm5gYHNbDBnL0zvBTkmjfC2DyoT3yUitUpdyf7DKxyVrXQ2HHbbSvNfVu9awakli8LzFWvzjV+zup0z3hokHAXckO/3EvpVefK+IDC+eTGz50P0taj9YkSEesAlnmB74vDbhev9pNomGF6WVXAVIsIT5BcKJptarFuepG17ecDifMOJISt6mbuJ5ZCrx80Lf672zZaFsb1Tjd5JoLyO9n2dZ7HBJbqUEUAp9cw8ie2rqQuoyNGwTbK2lAEcDZErWjqe4o8w+NXD1URzmO20MMN2bOrH8+dI6KfyLoJueJqD7XaHKiM41u0+82ITvYnML78RKBG0q/0sD2KNuWDWSdXpNIqa3nVhWZoGlAMQc/rrAuEAYyrAnyGTaZmgnREkU5v18HhhD+7Zpl4AKcBH371F276cOfLEJYXGZpdWmyjaGcLrNOCKpx+62FlVDQEcoGdiXYQ6Vw== sergiy@bidnyi.name\n'

// The live disk, carrying the runner registration, Docker image cache and
// /home/newt/synth-cache. Declared by name so adoption leaves it untouched.
param osDiskName = 'newt-synth-runner_OsDisk_1_5a97c75b74fe412ca2886c3977845b74'

// 0 means "do not declare diskSizeGB". ARM does not store this on the VM, so
// declaring it on the already-built VM is an addition, not a match, and is
// rejected the same way securityType was. A fresh build passes 128.
param osDiskSizeGb = 0

// --- ingress ----------------------------------------------------------------
param sshSourceAddressPrefix = '193.0.219.126/32'

// --- GitHub OIDC federated credential ---------------------------------------
param githubOwner = 'wortexx'
param githubOwnerId = '177997'
param githubRepo = 'newt'
param githubRepoId = '1350544657'
param githubEnvironment = 'azure'

// --- checkpoint storage -------------------------------------------------------
param storageAccountName = 'newtpnrcheckpoints'
param containerName = 'pnr-checkpoints'
param checkpointRetentionDays = 30

// --- runner registration ------------------------------------------------------
param keyVaultName = 'newt-ci-kv'
param runnerName = 'newt-synth-runner'
param runnerLabels = 'self-hosted-synth'

// customData is only read on a first boot, so it stays off while adopting the
// existing VM. The rehearsal and any rebuild pass true.
param provisionOnFirstBoot = false

// --- vault operator -----------------------------------------------------------
// Deliberately NOT committed: this is a person's AAD object ID, unlike the
// service-principal IDs elsewhere in this file. Export it at deploy time:
//   export KV_ADMIN_PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)
// Left unset, no operator grant is created. Deployments are incremental and
// never delete, so an existing grant survives a deploy that omits it.
param keyVaultAdminPrincipalId = readEnvironmentVariable('KV_ADMIN_PRINCIPAL_ID', '')

// --- cost guardrail -----------------------------------------------------------
param budgetAmount = 150
param budgetContactEmail = 'sergiy@bidnyi.name'
// Pinned rather than left to utcNow() so redeploys do not churn the budget.
param budgetStartDate = '2026-09-01'
// Matches the +10y end date ARM assigned when the budget was first created.
param budgetEndDate = '2036-09-01'
