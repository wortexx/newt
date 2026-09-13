# Azure infrastructure as code (infra-plan Phase 6)

## Why

Every Azure resource the CI lanes depend on — the `newt-synth-runner` VM and its network, the `newt-ci-identity` OIDC identity and its two role assignments, the `newtpnrcheckpoints` storage account with its lifecycle rule — was created by hand across `ci-synth-lane` (2026-09-02) and `ci-pnr-lane` (2026-09-03..13), and exists only as runbook prose plus whatever is live in the subscription. Three concrete gaps follow: a lost or damaged VM can only be rebuilt by a human replaying that prose (Docker, runner service, az CLI, the unattended-upgrades/needrestart hardening from the ci-pnr-lane runbook §3.2); the VM deliberately no longer patches itself (ci-pnr-lane design D12), and a reproducible rebuild is the intended fix for that; and there is no budget alert, so the hourly watchdog is the only cost backstop on a $1.216/h VM. Drift is invisible too — the unscoped `default-allow-ssh` NSG rule `az vm create` added was only caught by inspecting live state. Phase 6 is the last unbuilt infrastructure phase and everything it formalizes now exists to be described.

This change touches **CI/infrastructure only**. No RTL, sim, synth, backend, or sw changes.

## What Changes

- **Bicep description of the whole CI resource graph** under `infra/azure/`: VM (with its NIC, VNet, public IP, NSG), user-assigned identity + GitHub OIDC federated credential, both minimally-scoped role assignments, storage account + `pnr-checkpoints` container + 30-day lifecycle rule. Existing resources are adopted in place by a previewed, idempotent deployment — nothing is recreated.
- **Three new resources, all declared**: a Key Vault holding the runner-registration PAT; a system-assigned managed identity on the VM so it can read that secret; a resource-group-scoped monthly budget with e-mail alerts.
- **Reproducible runner host**: a cloud-init definition plus an idempotent provisioning script that brings a fresh VM to today's host state (Docker, az CLI, Actions runner as a systemd service, `apt-daily-upgrade.timer` disabled, needrestart override) and self-registers the runner using a short-lived token minted from the PAT in Key Vault. The same script converges the existing VM.
- **Infra validation in CI**: a GitHub-hosted workflow that builds and lints the Bicep on pull requests touching `infra/**`, with no Azure credentials.
- **Docs**: `docs/infra-plan.md` Phase 6 rewritten to what was built; the ci-pnr-lane runbook's "Resource summary for Phase 6 IaC" table gets a pointer to `infra/azure/`.

**Explicit non-goals** (decided with the user during planning): no Packer golden image (deferred to its own change — it adds a tool, an image store and a rebuild workflow); no spot VM or second VM for the synth lane (the single shared VM stays on-demand, since `detailed_route` does not checkpoint mid-run and cannot survive an eviction); no Terraform; the disabled DevTestLab auto-shutdown is left alone (Phase 9 deletes it after the watchdog is observed); no change to any workflow's runtime behaviour.

## Capabilities

### New Capabilities

- `azure-infrastructure`: what the CI's Azure footprint must satisfy — every resource declared in versioned templates and deployable idempotently with a preview gate; the runner host reproducible from the repository; runner registration via a PAT that lives only in Key Vault; the CI identity's scope staying exactly as bounded as today; and declared cost/ingress guardrails.

### Modified Capabilities

- `ci-pipeline`: one added requirement — infrastructure templates are validated (build + lint, no Azure access) on every pull request that touches them.

## Impact

- **New code**: `infra/azure/` (Bicep template(s), parameter file, cloud-init, provisioning script, README), `.github/workflows/infra.yml`.
- **Docs**: `docs/infra-plan.md` (Phase 6, Risks table), `README.md` pointer, archived ci-pnr-lane runbook cross-reference.
- **Azure**: first deployment adds a Key Vault, a budget and a system-assigned identity on the VM, and recreates the two role assignments under deterministic names (a gap of seconds, performed while no lane run is active). Everything else is adopted unchanged. Cost delta ≈ $0/month (Key Vault bills per operation — cents; budgets are free).
- **GitHub**: a fine-grained PAT (repo `wortexx/newt`, Administration read/write) is created by the user and stored only in Key Vault; nothing is added to repository secrets or variables.
- **Not changed**: `pnr.yml`, `synth.yml`, `vm-watchdog.yml`, `ci.yml`, the `newt-eda` image, the flow scripts, the VM's existing OS disk contents (runner registration, Docker image cache, synth cache).
