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

## 3.2 — Stop unattended-upgrades from killing long runs (2026-09-11)

Applied after `pnr-bringup-8` was killed 74 min into a ~30 h run. Root cause,
from `journalctl -b -1` on the VM: `apt-daily-upgrade.service` upgraded
`libc6` at 06:48:21, and `needrestart` then restarted every service linking
the new libc — including the GitHub Actions runner:

```
06:48:27 systemd[1]: Stopping actions.runner.wortexx-newt.newt-synth-runner.service
06:48:27 runsvc.sh[975]: Shutting down runner listener
```

which surfaces in Actions as `The runner has received a shutdown signal`.
Docker and containerd were restarted in the same sweep, so the job's own
container was exposed too. `apt-daily-upgrade.timer` fires daily and P&R
runs take 24–30 h, so **every** run crosses at least one window — this is
almost certainly also what produced `pnr-bringup-5`'s "lost communication
with the server" on 2026-09-08.

User decision: apply **both** mitigations. Run via
`az vm run-command invoke ... --command-id RunShellScript` (no SSH on this
VM). Note Run Command executes scripts with `sh` (dash), not bash — `set -o
pipefail` fails there.

```bash
# 1. No automatic package upgrades on the runner VM.
#    apt-daily.timer is deliberately left enabled: it only refreshes package
#    lists and pre-downloads, it never installs and never restarts services.
systemctl disable --now apt-daily-upgrade.timer

# 2. Even a hand-run apt upgrade must never auto-restart the runner or the
#    container runtime underneath a live job.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-ci-runner.conf <<'CONF'
$nrconf{override_rc}{qr(^actions\.runner\.)} = 0;
$nrconf{override_rc}{qr(^docker\.)} = 0;
$nrconf{override_rc}{qr(^containerd\.)} = 0;
CONF
```

Verified immediately after applying: `systemctl is-enabled
apt-daily-upgrade.timer` → `disabled`, `is-active` → `inactive`, and it no
longer appears in `systemctl list-timers 'apt-daily*'`; `needrestart -r l`
exits 0 (config parses); the runner service stayed `active` and the
in-flight `pnr-bringup-9` job container (`newt-eda:dev`) was undisturbed.

**Consequence to carry into Phase 6:** this VM no longer patches itself.
Security updates are now a deliberate act — apply them while the VM is idle
(`apt-get update && apt-get upgrade`, then restart the runner by hand), or
better, bake them into the Packer golden image Phase 6 plans. Both changes
are reversible: `systemctl enable --now apt-daily-upgrade.timer` and
`rm /etc/needrestart/conf.d/99-ci-runner.conf`.

## Resuming a run from a previous run's checkpoints (added 2026-09-12)

`run_pnr.sh` already skips any stage whose checkpoint zip is present
(design D1), so resuming is purely a matter of putting the zips back before
P&R starts. Two pieces make that possible in CI: `upload-checkpoints` has
always pushed them to `pnr-checkpoints/<run_id>/`, and a
`restore-checkpoints` job now pulls them back down.

To resume, point the lane at the run whose checkpoints you want:

```bash
# The run ID lives in a tracked file, so it travels with the tag.
echo <run_id> > .github/pnr-resume-from
git commit -am "resume from <run_id>" && git tag pnr-bringup-N
git push origin ci-pnr-lane pnr-bringup-N

# Afterwards, delete the file so later runs go back to the full flow:
git rm .github/pnr-resume-from && git commit -m "back to full runs"
```

A tracked file rather than a repository variable for two reasons: setting
repository variables needs permissions the CI token doesn't have, and a
committed run ID shows up in the tag's own diff instead of lingering
invisibly in repo settings, where it would silently resume every later run.
`PNR_RESUME_FROM_RUN` (repository variable) and the `resume_from_run`
workflow_dispatch input both still take precedence over the file if set —
prefer the dispatch input post-merge, since it needs no cleanup at all.

Safety: checkpoints hold the physical database for one specific synthesis
result, so grafting them onto a different netlist would silently produce a
layout for a design that was never synthesized. Each upload now carries a
`synth-key.txt` marker naming the netlist it came from, and the restore step
**refuses** to proceed if that marker disagrees with the current run's synth
cache key. Runs from before 2026-09-12 have no marker; the restore warns and
proceeds on the caller's assertion, so only resume from those when you know
the RTL and synthesis inputs are unchanged.

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
| VM host config | `apt-daily-upgrade.timer` disabled | unattended-upgrades restarted the runner mid-job and killed `pnr-bringup-8`; see section 3.2 |
| VM host config | `/etc/needrestart/conf.d/99-ci-runner.conf` | blocks auto-restart of `actions.runner.*`, `docker.*`, `containerd.*`; see section 3.2 |
