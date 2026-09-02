# ci-pnr-lane Azure/GitHub runbook (tasks 1.1–1.4)

Manual setup record, in the order run, for Phase 6's IaC (Terraform/Bicep) to
translate later — see `design.md` D8/D9 and the Migration Plan. Every command
below ran against subscription `c250fe80-fea5-4117-861f-e1461f526d8b`
("Azure subscription 1", tenant `8ddc1e59-1252-46dd-a154-aa2edf5481df`,
`sergiybidnyi.onmicrosoft.com`) and repo `wortexx/newt`. Resource group
(`newt-synth-lane-rg`, `swedencentral`) and VM (`newt-synth-runner`) already
existed from `ci-synth-lane`; nothing here recreates them.

## 1.1 — Managed identity, GitHub environment, federated credential

```bash
# One-time: register the resource provider (was NotRegistered on this subscription)
az provider register --namespace Microsoft.ManagedIdentity   # auto-triggered by the next command

az identity create --resource-group newt-synth-lane-rg --name newt-ci-identity
# -> clientId:    60617f62-7e05-45b3-9ebf-8e79025b6548
# -> principalId: 6e5681a6-e861-476f-a091-72d01bb57531

gh api --method PUT repos/wortexx/newt/environments/azure

# CORRECTED subject - see design.md D8's correction note. The plain form
# (repo:wortexx/newt:environment:azure) fails: this repo has stable/immutable
# OIDC subject claims enabled, so GitHub presents owner/repo numeric IDs.
# Confirmed via:
gh api users/wortexx --jq '.id'          # 177997
gh api repos/wortexx/newt --jq '.id'     # 1350544657

az identity federated-credential create \
  --name gh-actions-azure-env \
  --identity-name newt-ci-identity \
  --resource-group newt-synth-lane-rg \
  --issuer https://token.actions.githubusercontent.com \
  --subject "repo:wortexx@177997/newt@1350544657:environment:azure" \
  --audiences api://AzureADTokenExchange

gh variable set AZURE_CLIENT_ID       --env azure --repo wortexx/newt --body "60617f62-7e05-45b3-9ebf-8e79025b6548"
gh variable set AZURE_TENANT_ID       --env azure --repo wortexx/newt --body "8ddc1e59-1252-46dd-a154-aa2edf5481df"
gh variable set AZURE_SUBSCRIPTION_ID --env azure --repo wortexx/newt --body "c250fe80-fea5-4117-861f-e1461f526d8b"
```

**Verification**: a throwaway workflow (`environment: azure`, `azure/login@v2`
+ `az account show`) on a scratch branch (triggered on `push` — `workflow_dispatch`
requires the workflow to already be on the default branch, which a first-time
throwaway isn't) passed cleanly after the subject correction above and after
1.2's role existed. Scratch branch/workflow deleted afterward.

## 1.2 — Role assignment (VM)

```bash
VM_ID=$(az vm show --resource-group newt-synth-lane-rg --name newt-synth-runner --query id -o tsv)

az role assignment create \
  --assignee-object-id 6e5681a6-e861-476f-a091-72d01bb57531 \
  --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" \
  --scope "$VM_ID"
```

**Verification**: `az role assignment list --assignee 6e5681a6-... --all` shows
exactly this one assignment, scoped to the VM resource, nothing broader. Live
`az vm deallocate` then `az vm start` through the OIDC identity (same
throwaway workflow) both succeeded; VM confirmed `running` afterward.

## 1.3 — Storage account, container, lifecycle policy, role assignment

```bash
# One-time: register the resource provider (was NotRegistered)
az provider register --namespace Microsoft.Storage
# ... poll `az provider show --namespace Microsoft.Storage --query registrationState`
#     until "Registered" - took a few minutes.

az storage account check-name --name newtpnrcheckpoints   # nameAvailable: true

az storage account create \
  --name newtpnrcheckpoints \
  --resource-group newt-synth-lane-rg \
  --location swedencentral \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Cool \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage container create \
  --account-name newtpnrcheckpoints \
  --name pnr-checkpoints \
  --auth-mode key

# Lifecycle policy body: see below
az storage account management-policy create \
  --account-name newtpnrcheckpoints \
  --resource-group newt-synth-lane-rg \
  --policy @pnr-checkpoints-lifecycle.json

CONTAINER_SCOPE="/subscriptions/c250fe80-fea5-4117-861f-e1461f526d8b/resourceGroups/newt-synth-lane-rg/providers/Microsoft.Storage/storageAccounts/newtpnrcheckpoints/blobServices/default/containers/pnr-checkpoints"
az role assignment create \
  --assignee-object-id 6e5681a6-e861-476f-a091-72d01bb57531 \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$CONTAINER_SCOPE"

gh variable set AZURE_STORAGE_ACCOUNT --env azure --repo wortexx/newt --body "newtpnrcheckpoints"
```

`pnr-checkpoints-lifecycle.json`:

```json
{
  "rules": [
    {
      "enabled": true,
      "name": "expire-pnr-checkpoints-after-30-days",
      "type": "Lifecycle",
      "definition": {
        "actions": {
          "baseBlob": { "delete": { "daysAfterModificationGreaterThan": 30 } }
        },
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["pnr-checkpoints/"]
        }
      }
    }
  ]
}
```

**Verification**: throwaway workflow (same pattern as 1.1) uploaded then
listed a test blob under `pnr-checkpoints/_verify/` via OIDC — passed on the
first attempt. Test blob and scratch branch deleted afterward.

## 1.4 — VM host prep (az CLI, disk headroom)

No SSH access to the VM was available in this environment; used
`az vm run-command invoke` (Azure's Run Command feature, via the VM agent —
no SSH key needed) instead.

```bash
az vm run-command invoke \
  --resource-group newt-synth-lane-rg --name newt-synth-runner \
  --command-id RunShellScript \
  --scripts "curl -sL https://aka.ms/InstallAzureCLIDeb | bash"
# -> installed azure-cli 2.90.0-1~noble

az vm run-command invoke \
  --resource-group newt-synth-lane-rg --name newt-synth-runner \
  --command-id RunShellScript \
  --scripts "az version; df -h"
```

**Disk headroom result** (2026-09-03):

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       123G   13G  111G  10% /
/dev/sdb1       590G   32K  560G   1% /mnt
```

Docker (`/var/lib/docker`) and the GitHub runner (`/home/newt/actions-runner`,
including its `_work` job-workspace directory) both live on `/` — **111G
free, below the ~200GB/run budget** (docs/infra-plan.md Appendix A). `/mnt`
has plenty of room but is Azure's ephemeral local/temp disk: it does **not**
survive a VM deallocate, so nothing that must persist across this design's
own start/deallocate cycle (the runner's registration, Docker's pulled
image) can safely live there.

**User decision: accept the risk for now**, revisit if a real run (task 2.4
or 3.2) actually hits `ENOSPC`. If it does, resizing the OS disk (requires a
deallocate → `az disk update --size-gb <n>` → start cycle) is the
lower-risk fix — it doesn't touch the already-registered runner's config,
unlike remapping `_work` to `/mnt`. See design.md's Risks table.

## Resource summary for Phase 6 IaC

| Resource | Name | Notes |
| --- | --- | --- |
| Managed identity | `newt-ci-identity` | `clientId 60617f62-7e05-45b3-9ebf-8e79025b6548`, `principalId 6e5681a6-e861-476f-a091-72d01bb57531` |
| Federated credential | `gh-actions-azure-env` on `newt-ci-identity` | subject `repo:wortexx@177997/newt@1350544657:environment:azure` (owner/repo-ID form, not plain names) |
| GitHub environment | `azure` on `wortexx/newt` | carries `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`/`AZURE_STORAGE_ACCOUNT` as variables (not secrets) |
| Role assignment | Virtual Machine Contributor | scoped to `newt-synth-runner` VM resource only |
| Role assignment | Storage Blob Data Contributor | scoped to `pnr-checkpoints` container only |
| Storage account | `newtpnrcheckpoints` | `swedencentral`, `Standard_LRS`, `StorageV2`, Cool tier, public blob access disabled, TLS1.2 min |
| Container | `pnr-checkpoints` | 30-day delete lifecycle rule on `blockBlob` under `pnr-checkpoints/` prefix |
| VM host package | `azure-cli` 2.90.0 | installed on `newt-synth-runner` via Run Command (no SSH available) |
