# Design — azure-infra-as-code

## Context

See proposal.md for motivation. What shapes the approach:

- **Everything already exists and is in use.** Live inventory of `newt-synth-lane-rg` (`swedencentral`, subscription `c250fe80-…`, verified 2026-09-13): VM `newt-synth-runner` (`Standard_E16ds_v5`, `Canonical:ubuntu-24_04-lts:server:latest`, admin `newt`, `securityType: Standard`, **no managed identity**, on-demand); its OS disk `newt-synth-runner_OsDisk_1_5a97…` (128 GB Premium_LRS — holds the runner registration, Docker's image cache and `/home/newt/synth-cache`, all of which must survive); `newt-synth-runnerVMNic` / `newt-synth-runnerVNET` / `newt-synth-runnerPublicIP` (Standard SKU, static, `4.165.136.61`); `newt-synth-runnerNSG` with the single rule `AllowSSHFromMe` (prio 100, `193.0.219.126/32` → 22); the DevTestLab schedule `shutdown-computevm-newt-synth-runner` (`Disabled`, 10:00 UTC); identity `newt-ci-identity` (clientId `60617f62-7e05-45b3-9ebf-8e79025b6548`, principalId `6e5681a6-e861-476f-a091-72d01bb57531`) with federated credential `gh-actions-azure-env` (subject `repo:wortexx@177997/newt@1350544657:environment:azure` — the ID-embedded form, per ci-pnr-lane D8's correction); two role assignments with random GUID names (VM Contributor on the VM, Storage Blob Data Contributor on container `pnr-checkpoints`); storage account `newtpnrcheckpoints` (StorageV2, Standard_LRS, Cool, TLS1.2, no public blob) with lifecycle rule `expire-pnr-checkpoints-after-30-days`. No budget.
- **The workflows hardcode names** (`AZURE_RESOURCE_GROUP: newt-synth-lane-rg`, `AZURE_VM_NAME: newt-synth-runner`, container `pnr-checkpoints`, runner label `self-hosted-synth`). Renaming anything is out of the question; the templates must reproduce these names exactly.
- **Host state that the runbook records and a rebuild must reproduce** (ci-pnr-lane runbook §1.4/§3.2, ci-synth-lane task 1.1b): Docker via `get.docker.com`, `newt` in the `docker` group; Actions runner under `/home/newt/actions-runner` as a systemd service (`actions.runner.wortexx-newt.newt-synth-runner`), name `newt-synth-runner`, label `self-hosted-synth`; az CLI via `aka.ms/InstallAzureCLIDeb`; `apt-daily-upgrade.timer` disabled (`apt-daily.timer` deliberately left on); `/etc/needrestart/conf.d/99-ci-runner.conf` blocking auto-restart of `actions.runner.*`, `docker.*`, `containerd.*`.
- **Tooling on the dev machine**: `az` 2.90 with the Bicep CLI (0.44.1) already installed via `az bicep`; no Terraform, no Packer. There is no SSH to the VM from the agent's environment — host-side work goes through `az vm run-command invoke` (which executes with `sh`, not bash).
- **Harness constraint** (ci-synth-lane task 1.1a): mutating `az` commands were denied for agent execution by the permission classifier — the user ran provisioning by hand while the agent verified with read-only queries. Assume the same split here.
- **User decisions made during planning**: Bicep (not Terraform/OpenTofu); cloud-init provisioning script only, Packer golden image deferred; runner registration via a PAT stored in Key Vault.

## Goals / Non-Goals

**Goals:**

- One committed description of the CI resource graph that adopts the live resources without recreating anything, with a preview gate that makes a destructive deployment impossible to apply by accident.
- A fresh VM reaches today's host state, including runner registration, with no human on the box.
- The CI identity's blast radius does not grow: it gets nothing new, and the only new credential (the PAT) is readable only by the VM itself.

**Non-Goals:**

- Applying infrastructure from CI (see D6 — it would require RG-level Contributor + RBAC rights on an OIDC identity the specs require to stay bounded).
- Private endpoints / disabling public network access on the Key Vault or storage account — a single secret and intra-region blob traffic don't justify the VNet plumbing.
- Managing GitHub-side state (the `azure` environment, its variables, branch protection) — GitHub has no first-class IaC here; the runbook stays the record for that.
- Multi-environment / multi-region parameterisation. One RG, one VM.

## Decisions

### D1: Bicep, one resource-group-scoped deployment, incremental mode

`infra/azure/main.bicep` (`targetScope = 'resourceGroup'`) with `main.bicepparam`, deployed with `az deployment group what-if` then `az deployment group create`. Split into modules (`network.bicep`, `vm.bicep`, `identity.bicep`, `storage.bicep`, `keyvault.bicep`, `budget.bicep`) only if the flat file passes ~300 lines — implementer's call. The resource group itself is not declared: it is a one-liner (`az group create`) recorded in `infra/azure/README.md`, and declaring it would force a subscription-scope deployment for a single line.

Why Bicep over Terraform/OpenTofu: ARM *is* the state — no backend storage account to bootstrap by hand before the tool that is supposed to manage storage accounts can run; adopting the nine existing resources is a plain PUT of matching properties rather than one `import` per resource; federated credentials, role assignments, blob lifecycle policies and consumption budgets are all first-class resource types; the CLI is already installed. Terraform's advantages (portability, ecosystem) don't apply to a single-RG, single-cloud, solo repo. Incremental mode (the default) is essential, not incidental: it is what leaves the undeclared auto-shutdown schedule alone (D2) and what makes "nothing is deleted by a deployment" true by construction — complete mode is never used.

### D2: Adopt the live resources in place; the first deployment's diff is known in advance

Each existing resource is declared with its live properties so the first `what-if` shows `NoChange` or benign `Modify` only. The changes the first deployment *will* make, deliberately:

- **VM gains `identity: { type: 'SystemAssigned' }`** — an in-place update, no reboot, no effect on the OS disk.
- **Both role assignments are recreated under deterministic names** (`guid(scope, principalId, roleDefinitionId)`), because the hand-made ones have random GUID names Bicep cannot adopt, and ARM rejects a second assignment of the same principal/role/scope under a different name. Procedure: delete the two hand-made assignments immediately before `create`, while no lane run is active — the identity is without rights for the seconds between the two commands. Verified afterwards by listing the identity's assignments: same two roles, same two scopes.
- **VM `customData`** (the cloud-init, D3) is only honoured at first boot, so declaring it is inert for the existing VM. What-if may report it as a change on the first deployment because ARM does not return `customData` on GET; that is expected and accepted, and the second deployment must read `NoChange`.
- **The OS disk is never declared standalone** — it is referenced through the VM's `storageProfile.osDisk` with `createOption: 'FromImage'` and the live name, which is the adoption path that leaves its contents alone.
- **The DevTestLab auto-shutdown schedule is deliberately not declared.** Incremental mode leaves it in place; Phase 9 deletes it by hand after the watchdog has been observed working (ci-pnr-lane D6 step 3: never a window with no cost backstop). The drift check (task 2.5) lists it as the one expected exception.

Alternatives considered: a full recreate into a new RG (throws away the OS disk's runner registration and caches, and every workflow's hardcoded names — no); Terraform `import` blocks (works, but every resource needs one and a state backend first — see D1).

### D3: Host provisioning = `cloud-init.yaml` wrapping an idempotent `provision-runner.sh`

`infra/azure/provision-runner.sh` is a bash script that converges the host in idempotent steps, each guarded by a check so a re-run changes nothing: Docker (official convenience script, skipped if `docker` is on PATH) + `usermod -aG docker newt`; az CLI (skipped if `az` exists); `systemctl disable --now apt-daily-upgrade.timer`; write `/etc/needrestart/conf.d/99-ci-runner.conf` with the exact three override lines from the runbook; then runner registration (D4) only if `/home/newt/actions-runner/.runner` does not already exist. The runner release is resolved dynamically from `repos/actions/runner/releases/latest` as ci-synth-lane 1.1b did, not pinned. Registration uses `config.sh --unattended --replace --name newt-synth-runner --labels self-hosted-synth --url https://github.com/wortexx/newt` followed by `svc.sh install newt && svc.sh start` — `--replace` is what lets a rebuilt VM take over the old runner's name without a manual delete on the GitHub side.

`infra/azure/cloud-init.yaml` embeds the script via `write_files` and runs it from `runcmd` with `bash` — the VM's `customData` parameter is the base64 of this file. The same script converges the **existing** VM through `az vm run-command invoke --scripts` (which runs under `sh`, hence the explicit `bash` invocation and no `set -o pipefail` at the sh level); on that host every step is expected to be a no-op except writing nothing — the point is to prove the script matches reality, not to change the VM.

Why a script rather than only cloud-init modules: the same file must run on the existing VM (cloud-init has already completed there), from run-command, and by hand — one artifact, three entry points. Why not Packer: the user deferred it; a script that a Packer template could later call is the right stepping stone anyway.

### D4: Registration PAT lives only in Key Vault; the VM's own identity reads it

Key Vault (`newt-ci-kv` unless the name is taken — it is global; the parameter file records the final name): RBAC authorisation mode, soft-delete on, purge protection on, public network access on (the VM has no private endpoint; the vault holds one secret readable by one identity). Secret `github-runner-pat` is **set by hand** (`az keyvault secret set`) and never declared in Bicep — declaring it would put the value in a parameter or a deployment history. The VM's system-assigned identity gets **Key Vault Secrets User** at vault scope, declared in Bicep with a deterministic name. `newt-ci-identity` gets nothing on the vault.

The PAT is a fine-grained token on `wortexx/newt` with the "Administration: read and write" repository permission (the one that covers self-hosted runner registration), one-year expiry, recorded in the README with the expiry date so rotation is a known chore: `az keyvault secret set` again, then re-run provisioning if a rebuild is needed. The script fetches the secret with the IMDS token (`curl -H Metadata:true http://169.254.169.254/metadata/identity/oauth2/token?resource=https://vault.azure.net`), exchanges it for a registration token (`POST /repos/wortexx/newt/actions/runners/registration-token`), and holds both only in shell variables — nothing is written to disk, and the script never echoes them.

Alternatives: a GitHub App (cleanest, but private-key handling plus JWT minting for a solo repo — user declined); manual token at build time (user declined in favour of unattended rebuilds).

**Correction found at task 3.1: this decision was incomplete.** It says the secret is "set by hand" without saying who may. The vault is RBAC-authorised, so subscription Owner confers no data-plane rights and `az keyvault secret set` fails with `Forbidden`; a human operator needs **Key Vault Secrets Officer** at vault scope. That grant is now declared, behind a `keyVaultAdminPrincipalId` parameter the committed parameter file reads from the environment (`readEnvironmentVariable`), so the operator's AAD object ID — the one identifier here that names a person rather than a service principal — stays out of a public repository. There is no set-only Key Vault role, so this principal can also read the secret; that is an accepted consequence of a human having to install it at all, and it does not touch the invariant the spec actually protects, which is that `newt-ci-identity` has no vault access.

### D5: Budget declared at resource-group scope

`Microsoft.Consumption/budgets` at RG scope, `timeGrain: Monthly`, `startDate` = first day of the deployment month (a parameter with that default, since ARM rejects a start date in the past beyond the current period), notifications at 50 %, 80 % and 100 % of **actual** cost to a parameterised e-mail. Default amount $150 — the plan's Risks-table estimate for the deallocate-by-default regime. This is a notification, not an enforcement: nothing stops the VM. The watchdog remains the enforcement.

### D6: Humans deploy; CI only validates

Deploying is `az deployment group what-if` → read the diff → `az deployment group create`, from the dev machine under the user's own `az login`. `.github/workflows/infra.yml` runs on `pull_request` and `push: main` with `paths: [infra/**, .github/workflows/infra.yml]` and does `az bicep build` (which runs the linter; `bicepconfig.json` promotes lint findings to errors) plus `shellcheck` on the provisioning script — no `azure/login`, no environment, no `id-token` permission. A CI deployer would need Contributor + Role Based Access Control Administrator on the RG, which the `azure-infrastructure` spec forbids for `newt-ci-identity`, and a second, privileged OIDC identity for a repo that deploys infrastructure a few times a year isn't worth its own attack surface. `what-if` from CI is also rejected for the same reason: it needs Reader on the RG, which already widens the identity.

### D7: Parameters are non-secret and committed

`main.bicepparam` is checked in with: SSH source CIDR (`193.0.219.126/32`), the `newt` user's SSH public key (public by definition; the same key `az vm show` reports), GitHub owner/repo numeric IDs for the federated-credential subject (`177997`, `1350544657`), budget amount and recipient e-mail, Key Vault name. All of these are already in the repository's history via the archived runbooks. No `@secure()` parameter exists, so a deployment never needs a value typed in — the PAT is the sole secret and lives only in Key Vault (D4).

### D8: Rehearse a fresh build on a throwaway VM before trusting the rebuild path

The spec's "fresh VM provisioned from the template" scenario is only provable by provisioning a fresh VM. Doing that with `Standard_E16ds_v5` costs real money and — worse — would register a second runner named `newt-synth-runner` (`--replace` would steal the real one's registration). So the template takes `vmName`, `vmSize`, `runnerName` and `runnerLabels` as parameters, and the rehearsal deploys into a scratch resource group (`newt-iac-rehearsal-rg`) with `Standard_B2s`, runner name `newt-iac-rehearsal`, label `iac-rehearsal`, pointing at the **real** Key Vault (its identity gets a temporary Secrets User assignment, part of the rehearsal deployment). Success = runner online with the scratch label, `docker run hello-world` as `newt`, `az version`, timer disabled, override file present, then a second script run reports no changes. Teardown: `az group delete` plus `gh api -X DELETE repos/wortexx/newt/actions/runners/<id>` for the scratch runner and removal of the temporary vault assignment (it goes with the scratch identity when the RG is deleted, but ARM leaves an orphaned assignment entry — delete it explicitly). Cost: cents.

### D9: Deploy steps are user-executed; the agent verifies read-only

Mirrors ci-synth-lane 1.1a: `az deployment group create`, `az role assignment delete`, `az keyvault secret set`, `az vm run-command invoke`, `az group create/delete` are expected to be denied for agent execution. tasks.md marks each such step **(user)**; the agent prepares the exact command, the user runs it, and the agent verifies the outcome with read-only queries (`what-if`, `az resource list`, `az role assignment list`, `az vm show`, `gh api .../runners`). `what-if` itself is read-only and is expected to be agent-runnable.

## Risks / Trade-offs

- **[`what-if` reports `Replace` on the VM for an immutable property — image `exactVersion`, `osProfile`, disk name]** → the template is adjusted to the live value (`version: 'latest'` with the live `exactVersion` ignored; `createOption: 'FromImage'` with the live disk name; `linuxConfiguration.disablePasswordAuthentication: true` with the live key). A `Replace` is never applied; task 2.1 loops until the preview is clean. If a property genuinely cannot be matched, the VM is declared with `existing` and only its identity is added via a separate `Microsoft.Compute/virtualMachines` update — documented as a spec gap rather than forced.
- **[Role-assignment recreation window]** → seconds, done while no lane run is active (check `gh run list` for both lanes first); if a lane started in that window its `start` job fails loudly and can simply be re-dispatched — no data at risk.
- **[Key Vault name already taken globally]** → pick another; the parameter file is the record.
- **[Rehearsal `--replace` steals the real runner's registration]** → the rehearsal uses a distinct `runnerName`; the script refuses to run registration if `RUNNER_NAME` is empty.
- **[PAT expiry silently breaks rebuilds a year from now]** → expiry date recorded in `infra/azure/README.md`; the script fails with an explicit "registration-token request returned 401 — rotate `github-runner-pat`" message rather than a bare curl error.
- **[ARM rejects any VM property the live VM does not already store — `PropertyChangeNotAllowed`]** → hit three times at task 2.2, each time as a *failed deployment*, never as a preview finding. (1) `securityProfile.securityType`: the template declared exactly the `Standard` that `az vm show` reports, but the VM was created with no stored `securityType` and `Standard` is only what GET synthesises for its absence, so declaring it is an addition. (2) `linuxConfiguration.ssh.publicKeys`: the stored `keyData` ends in a newline that was lost capturing it with `tr -d '\n'`; a one-byte difference is a change. (3) `storageProfile.osDisk.diskSizeGB`: ARM does not store it on the VM at all, so it was the same addition pattern, caught pre-emptively rather than by a fourth failed deployment. **The generalisation, and the reason this belongs in the design rather than a task note: `what-if` reports every one of these as a benign property-level `Create`, identical in appearance to the `identity: Create` that is the whole point of the deployment. A clean preview is necessary but not sufficient — it does not evaluate whether a property may be changed.** The check that actually works is to diff every leaf the template sets against the live GET and treat *absent on live* as the danger signal; that check now passes with zero mismatches. Both properties that cannot be matched are behind parameters that omit them entirely (`securityType`, and `osDiskSizeGb == 0`), so a fresh build still gets `Standard` and a 128 GB disk while adoption sends neither.
- **[`what-if` reports a permanent `Modify` on the NIC for properties that cannot be declared]** → confirmed at task 2.1: `kind` and `properties.allowPort25Out` are read-only and ARM-computed, and Bicep rejects both (`BCP187`, `BCP037`), so every preview shows them as deletes and no deployment can actually remove them. Every *writable* property was declared at its live value, which cleared the same noise on the VNet, the blob service and the container — the blob service is now referenced with `existing` rather than written, since a PUT with empty properties was predicted to wipe its CORS and retention settings. The NIC residue is documented as the known exception the `azure-infrastructure` spec now carves out; leaving the NIC undeclared to get a clean preview was rejected, because the spec requires it to be declared.
- **[Bicep linter false positives (e.g. `securityType: 'Standard'`, public network access on the vault)]** → per-line `#disable-next-line` with the justification in a comment, never a global rule disable.
- **[Converging the existing VM via run-command disturbs the live runner]** → every step is guarded to be a no-op on that host; registration is skipped because `.runner` exists; `needrestart` config write is idempotent. Run while the VM is idle (check the runner's `busy` flag) regardless.
- **[Budget notifications never fire because Cost Management data lags]** → accepted; this is a monthly guardrail, not the live backstop (the watchdog is).
- **[`customData` shows as a perpetual `Modify` in what-if]** → did not materialise. `provisionOnFirstBoot` defaults to false and the adopted VM's parameter file leaves it false, so `customData` is never emitted for that VM and does not appear in the preview at all (task 2.1). The split this row describes is not needed; the parameter it proposed exists anyway, because the rehearsal and any rebuild need it.

## Migration Plan

1. Author templates + script; `az bicep build` and `shellcheck` clean locally (no Azure needed).
2. `what-if` loop against the live RG until the preview shows only the intended first-deployment changes from D2.
3. Confirm no lane run is active; user deletes the two hand-made role assignments and runs `az deployment group create`. Agent verifies: role assignments (same roles/scopes), VM identity present, vault and budget exist, second `what-if` is clean.
4. Prove the OIDC path still works: dispatch `vm-watchdog.yml` (post-merge) or, pre-merge, a synth-lane `workflow_dispatch` — either exercises VM read/deallocate via `newt-ci-identity`.
5. User creates the PAT and sets `github-runner-pat`.
6. Rehearsal (D8) in a scratch RG; tear down.
7. Converge the existing VM via run-command; confirm idempotence and that the runner stays online.
8. Land `infra.yml`; update docs.

Rollback: every deployment is incremental and additive to what existed, so "rollback" is deleting the three new things by hand (`az keyvault delete` + purge, `az consumption budget delete`, `az vm identity remove`) and, if the deterministic role assignments were created, leaving them — they are functionally identical to the old ones. The VM, disk, network, identity, credential and storage are never touched destructively by any step.

## Open Questions

- ~~Whether `customData` needs to be split out for the adopted VM (Risks, last row)~~ — **resolved at task 2.1, earlier than expected.** No split is needed: with `provisionOnFirstBoot` false the property is never emitted for the adopted VM, and the preview shows no `customData` entry at all.
- Budget default of $150/month — tune freely once a few months of deallocate-by-default billing exist; a parameter, not a design point.
