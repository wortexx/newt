# CI Azure infrastructure

Everything the CI lanes need in Azure, declared in Bicep — `docs/infra-plan.md`
Phase 6. This directory is the source of truth for those resources; the
archived [ci-pnr-lane runbook][runbook] records how they were originally built
by hand, but is no longer the authority.

| File | What it is |
| --- | --- |
| `main.bicep` | The whole resource graph, resource-group scoped |
| `main.bicepparam` | Parameters for the live group, `newt-synth-lane-rg` |
| `modules/keyvault-secrets-user.bicep` | One role assignment, in the vault's own group |
| `provision-runner.sh` | Idempotent host provisioning; converges a fresh or existing VM |
| `cloud-init.yaml` | First-boot wrapper; embeds the script as `customData` |
| `bicepconfig.json` | Linter config — findings are errors, not warnings |

[runbook]: ../../openspec/changes/archive/2026-09-13-ci-pnr-lane/runbook.md

## Deploying

Deployments are run by a human from a machine logged in with `az login`. CI
never deploys and never holds Azure credentials — it only builds and lints
(`.github/workflows/infra.yml`, design D6).

The resource group itself is not declared; it is one line, run once:

```bash
az group create --name newt-synth-lane-rg --location swedencentral
```

Before either command, export the operator's object ID. It is not committed —
it names a person, unlike the service-principal IDs in `main.bicepparam` — so
the parameter file reads it from the environment:

```bash
export KV_ADMIN_PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)
```

This grants you **Key Vault Secrets Officer**, which is what lets you set and
rotate `github-runner-pat`. Deploy without it and no operator grant is created;
because deployments are incremental and never delete, an existing grant simply
survives untouched. So the failure mode is "a new operator has no access", never
"access was revoked".

Always preview, then apply:

```bash
# 1. Preview. Read every line before continuing.
az deployment group what-if \
  --resource-group newt-synth-lane-rg \
  --template-file infra/azure/main.bicep \
  --parameters infra/azure/main.bicepparam

# 2. Apply, only if the preview shows no Delete and no Replace.
az deployment group create \
  --resource-group newt-synth-lane-rg \
  --template-file infra/azure/main.bicep \
  --parameters infra/azure/main.bicepparam
```

Deployments are **incremental** (the default). Complete mode is never used:
incremental is what leaves the undeclared auto-shutdown schedule alone and what
makes "a deployment never deletes anything" true by construction.

**Never apply a preview showing `Delete` or `Replace`.** Fix the template so
the preview is clean instead. A `Replace` on the VM would destroy the OS disk,
taking the runner registration, the Docker image cache and
`/home/newt/synth-cache` with it.

### The first deployment's diff

Adopting the hand-built resources is expected to report exactly these changes
(design D2) and nothing else:

- **`Create`** — Key Vault, its Secrets User assignment for the VM identity,
  the budget, and the two role assignments under deterministic `guid()` names.
- **`Modify`** — the VM gains `identity.type: SystemAssigned` (an in-place
  update: no reboot, no effect on the OS disk). `customData` may also appear
  here because ARM does not return it on GET; that is inert for an existing VM,
  since cloud-init only reads it on a first boot.
- **`NoChange`** — everything else: network, VM, disk, identity, federated
  credential, storage account, container, lifecycle rule.

The two role assignments need one manual step first. The hand-made ones have
random GUID names Bicep cannot adopt, and ARM rejects a second assignment of
the same principal, role and scope under a different name — so delete them
immediately before deploying, **while no lane run is active or queued**:

```bash
# Check first: nothing running, nothing queued, runner not busy.
gh run list --workflow=synth.yml --limit 5
gh run list --workflow=pnr.yml --limit 5
gh api repos/wortexx/newt/actions/runners --jq '.runners[] | {name, status, busy}'

# Then delete both, and deploy straight away.
az role assignment delete --ids \
  "/subscriptions/c250fe80-fea5-4117-861f-e1461f526d8b/resourceGroups/newt-synth-lane-rg/providers/Microsoft.Compute/virtualMachines/newt-synth-runner/providers/Microsoft.Authorization/roleAssignments/9ad63b4f-a6f6-409c-b1cb-898de71df4df" \
  "/subscriptions/c250fe80-fea5-4117-861f-e1461f526d8b/resourceGroups/newt-synth-lane-rg/providers/Microsoft.Storage/storageAccounts/newtpnrcheckpoints/blobServices/default/containers/pnr-checkpoints/providers/Microsoft.Authorization/roleAssignments/868438f0-9ab7-48c2-8b56-70a36e99d09b"
```

The CI identity is without rights for the seconds between the two commands. If
a lane did start in that window its `start` job fails loudly and can simply be
re-dispatched — no data is at risk.

**This applies to any hand-made role assignment, not just those two.** `az role
assignment create` names an assignment with a random GUID; the templates use a
deterministic `guid(scope, principal, role)` name. ARM refuses a second
assignment of the same principal, role and scope under a different name, so a
grant made by hand must be deleted before a deployment can adopt it — otherwise
the deployment fails with `RoleAssignmentExists`. Check with `az role assignment
list --scope <resource id>` and compare the `name` field against the preview.

## The runner registration PAT

`provision-runner.sh` registers a runner without a human on the box by reading
a GitHub PAT from Key Vault as the VM's **own** system-assigned identity,
exchanging it for a short-lived registration token, and holding both only in
shell variables. Nothing is written to disk and nothing is echoed.

`newt-ci-identity` — the identity the workflows use — deliberately has **no**
access to the vault. Only the VM can read the secret.

The token is a fine-grained PAT on `wortexx/newt` with **Administration: read
and write** (the permission that covers self-hosted runner registration) and
nothing else. It is never declared in Bicep: that would put its value in a
parameter file or the deployment history.

- **Expires: 2026-12-13.** A 90-day token, not the one-year the plan originally
  assumed — so rotation is a quarterly chore. The Key Vault secret carries the
  same date as its `expires` attribute, so `az keyvault secret list` shows the
  deadline without anyone having to remember this file.

**Before you can set it**, you need data-plane access. The vault uses RBAC, so
subscription Owner is not enough — Owner grants management rights, not secret
access, and `az keyvault secret set` fails with `Forbidden` without this:

```bash
az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee-object-id <your AAD object ID> \
  --assignee-principal-type User \
  --scope "$(az keyvault show --name newt-ci-kv --query id -o tsv)"
```

To set or rotate the secret, pass it as a **file**, never as `--value`: a value
on the command line lands in shell history and in the process list.

```bash
umask 077
read -rs PAT && printf '%s' "${PAT//[[:space:]]/}" > /tmp/pat.txt && unset PAT

az keyvault secret set \
  --vault-name newt-ci-kv \
  --name github-runner-pat \
  --file /tmp/pat.txt \
  --expires <the new token's expiry, ISO 8601> \
  --output none

rm -P /tmp/pat.txt
```

The `${PAT//[[:space:]]/}` is not paranoia: a trailing space picked up by a
terminal paste is invisible, stores happily, and then surfaces months later as
an opaque `401` during a rebuild. `provision-runner.sh` strips whitespace when
reading the secret for the same reason.

Check a stored token without printing it:

```bash
az keyvault secret show --vault-name newt-ci-kv --name github-runner-pat \
  --query value -o tsv | wc -c        # expect 94 (93 + newline from tsv)
```

Rotation needs no template or workflow edit. Existing runners keep working —
the PAT is only read when a runner registers, so a rotation matters at the next
rebuild. If the PAT has expired, provisioning fails with an explicit message
naming the secret to rotate rather than a bare curl error.

## Rebuilding the VM from scratch

`provisionOnFirstBoot=true` attaches `cloud-init.yaml` as `customData`, which
writes `provision-runner.sh` to the new host and runs it: Docker, the `docker`
group, the Azure CLI, `apt-daily-upgrade.timer` disabled, the needrestart
override, then runner download and registration.

```bash
az deployment group create \
  --resource-group newt-synth-lane-rg \
  --template-file infra/azure/main.bicep \
  --parameters infra/azure/main.bicepparam \
  --parameters provisionOnFirstBoot=true osDiskName='' osDiskSizeGb=128
```

`osDiskName=''` lets the disk name derive from `vmName` instead of adopting the
old disk. `osDiskSizeGb=128` is needed because the parameter file sets it to 0
for adoption; without it the VM would get the image default of 30 GB.

**`securityType` is left unset, and that is what produces parity.** ARM refuses
to add it to the existing VM (`PropertyChangeNotAllowed`) *and* refuses the
value `Standard` on a new one unless the preview feature
`Microsoft.Compute/UseStandardSecurityType` is registered — so the template
never sends it. Omitting it does not opt into Trusted Launch: a raw template
with no `securityProfile` produces a Standard VM, because Trusted Launch is a
default applied by the portal and `az vm create` convenience paths, not by ARM.
Verified during the task 3.2 rehearsal: the scratch VM and the live runner
report an identical `securityProfile` of `{ "securityType": "Standard" }`. The runner registers with `--replace`, so it takes over the existing
`newt-synth-runner` registration on the GitHub side with no manual delete.

To rehearse this safely on a throwaway VM instead of the real one, deploy into
a scratch group with a distinct runner name — a rehearsal that reused
`newt-synth-runner` would have `--replace` steal the real runner's registration:

```bash
az group create --name newt-iac-rehearsal-rg --location swedencentral

az deployment group create \
  --resource-group newt-iac-rehearsal-rg \
  --template-file infra/azure/main.bicep \
  --parameters infra/azure/main.bicepparam \
  --parameters vmName=newt-iac-rehearsal vmSize=Standard_D2ds_v4 \
               runnerName=newt-iac-rehearsal runnerLabels=iac-rehearsal \
               provisionOnFirstBoot=true osDiskName='' osDiskSizeGb=128 \
               deployCiIdentity=false deployStorage=false \
               deployKeyVault=false deployBudget=false \
               keyVaultResourceGroupName=newt-synth-lane-rg
```

The SKU is not arbitrary. `Standard_B2s` does not exist in `swedencentral` at
all, and `Standard_B2s_v2` has a family quota of **0** on this subscription;
`Standard_D2ds_v4` is region-available with quota to spare. Check before
assuming any size is deployable:

```bash
az vm list-usage --location swedencentral -o table   # family quota headroom
az vm list-skus --location swedencentral --size Standard_D2 --resource-type virtualMachines -o table
```

Note that a deallocated VM still holds its cores: the real runner keeps
`Standard EDSv5` at 16/16 even while it is switched off.

The `deploy*=false` flags keep the scratch group to just a VM and its network:
the storage account name is globally unique and already taken, and a second CI
identity or budget would be meaningless. `keyVaultResourceGroupName` points the
scratch VM at the real vault, so it can read the PAT; that grant is a real role
assignment and must be removed at teardown:

```bash
az group delete --name newt-iac-rehearsal-rg --yes
gh api -X DELETE repos/wortexx/newt/actions/runners/<runner-id>
az role assignment delete --ids <the scratch identity's vault assignment>
```

## Converging the existing VM

The same script runs against the live host through Run Command — there is no
SSH from CI. Leave `RUNNER_NAME` unset so registration is skipped; the script
also refuses to re-register while `/home/newt/actions-runner/.runner` exists,
so the live registration is protected twice over.

Run it while the runner is idle:

```bash
gh api repos/wortexx/newt/actions/runners --jq '.runners[] | {name, status, busy}'

az vm run-command invoke \
  --resource-group newt-synth-lane-rg \
  --name newt-synth-runner \
  --command-id RunShellScript \
  --scripts @infra/azure/provision-runner.sh
```

Run Command executes scripts with `sh`, not bash — that is why the file carries
a bash shebang and is invoked as `bash` from `cloud-init.yaml`. On an
already-provisioned host every step logs `ok (already satisfied)` and nothing
changes; a second invocation produces identical output.

## Drift check

Incremental deployments never delete, so a resource created by hand outside the
templates will simply persist. Check for that periodically:

```bash
az resource list --resource-group newt-synth-lane-rg \
  --query "sort_by([].{name:name, type:type}, &name)" -o table
```

Every resource must map to one declared in `main.bicep`. As of 2026-09-13 the
group holds ten resources and all ten are accounted for:

| Resource | Type | Declared as |
| --- | --- | --- |
| `newt-synth-runner` | `Microsoft.Compute/virtualMachines` | `vm` |
| `newt-synth-runnerVMNic` | `Microsoft.Network/networkInterfaces` | `nic` |
| `newt-synth-runnerVNET` | `Microsoft.Network/virtualNetworks` | `vnet` |
| `newt-synth-runnerPublicIP` | `Microsoft.Network/publicIPAddresses` | `publicIp` |
| `newt-synth-runnerNSG` | `Microsoft.Network/networkSecurityGroups` | `nsg` |
| `newt-ci-identity` | `Microsoft.ManagedIdentity/userAssignedIdentities` | `ciIdentity` (+ its federated credential) |
| `newtpnrcheckpoints` | `Microsoft.Storage/storageAccounts` | `storageAccount` (+ container, lifecycle rule) |
| `newt-ci-kv` | `Microsoft.KeyVault/vaults` | `keyVault` |
| `newt-synth-runner_OsDisk_1_5a97…` | `Microsoft.Compute/disks` | **not declared standalone** — referenced through `vm.storageProfile.osDisk`, which is the adoption path that leaves its contents alone |
| `shutdown-computevm-newt-synth-runner` | `Microsoft.DevTestLab/schedules` | **the one exception** — see below |

The DevTestLab schedule is disabled and deliberately undeclared:
`docs/infra-plan.md` Phase 9 deletes it once `vm-watchdog.yml` has been observed
working, so that there is never a window with no cost backstop.

Anything else that appears is drift: either add it to the templates or delete
it.

Two entries always show as `Modify` in a preview even when nothing has changed,
and no deployment can settle them — they are exempted by the
`azure-infrastructure` spec rather than chased:

- the NIC's `kind` and `properties.allowPort25Out`, which are read-only and
  ARM-computed, so Bicep refuses to declare them (`BCP187` / `BCP037`);
- both role assignments' `principalId`, which the template supplies from a
  runtime `reference()` that the preview cannot resolve. The stored values are
  correct; check with `az role assignment list` rather than believing the diff.

## Cost guardrails

The budget is a **notification, not an enforcement** — nothing stops the VM
when a threshold is crossed. It alerts at 50 %, 80 % and 100 % of actual
monthly spend against `budgetAmount` (default $150). `vm-watchdog.yml` is the
mechanism that actually bounds spend, by deallocating an idle VM every hour.
