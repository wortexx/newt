# Tasks — apm-makefile-bootstrap

Legend: **[edit]** plain file edit, cheaply verified locally — no EDA tools or long runs needed for any task in this change.

## 1. Makefile plumbing

- [x] 1.1 **[edit]** Create root-level `apm.mk` with a `.PHONY: apm` target that guards on `command -v apm` (fails with an install hint, e.g. `brew install apm`, if missing) and otherwise runs `apm install`. Verify: `make apm` succeeds when `apm` is on `PATH`, and fails with a readable error message when temporarily removed from `PATH` (e.g. `PATH=/usr/bin make apm`).
- [x] 1.2 **[edit]** Add `include apm.mk` to the top-level `Makefile`, alongside the existing `include iguana.mk`. Verify: `make -n apm` (dry run) resolves the target without "No rule to make target" errors.

## 2. Version control

- [x] 2.1 **[edit]** Add `.gitignore` entries for `.claude/agents/`, `.claude/rules/`, and the 7 apm-declared skill directories (`.claude/skills/az-cost-optimize/`, `.claude/skills/azure-deployment-preflight/`, `.claude/skills/azure-pricing/`, `.claude/skills/azure-well-architected-review/`, `.claude/skills/docs-sync-audit/`, `.claude/skills/github-actions-efficiency/`, `.claude/skills/github-actions-hardening/`). Verify: `git status --short` no longer lists these paths as untracked.
- [x] 2.2 **[edit]** Confirm hand-authored `.claude/` content is unaffected. Verify: `git check-ignore -v .claude/commands/opsx/propose.md .claude/skills/systemverilog-style` reports no match (still tracked/trackable), and `git status --short` still shows `apm.yml`/`apm.lock.yaml` as trackable (not ignored).

## 3. Docs

- [x] 3.1 **[edit]** Add a one-line "run `make apm` after cloning to set up Claude Code agents/skills" note to `README.md`'s setup/getting-started section. Verify: the line renders correctly and sits next to the repo's other one-time setup steps (e.g. Docker/Bender setup, if documented there).

## 4. End-to-end verification

- [x] 4.1 **[edit]** Delete the currently-present apm-managed directories (`.claude/agents/`, `.claude/rules/`, the 7 apm skill dirs) and run `make apm`. Verify: the directories are regenerated with content matching `apm.lock.yaml`'s `deployed_files`/hashes (`apm install --dry-run -v` afterward reports nothing to change), and `git status --short` shows a clean tree for those paths (ignored, not untracked).
  - Deleted all 9 apm-managed directories, ran `make apm`: regenerated them, and `shasum -a 256` on sample files (`bicep-implement.md`, `azure-pricing/SKILL.md`) matched the pre-delete hashes exactly.
  - Deviation from the stated verification: `apm install --dry-run -v` does *not* report "nothing to change" — this apm version's dry-run mode always lists every manifest dependency as `-> install` (it explicitly skips the file-diffing "integration" phase: "[dry-run] ... is not previewed -- it requires running integration"). The actually meaningful idempotency signal is the plain `make apm` (non-dry-run) re-run, which reported `(files unchanged)` per dependency and `No changes -- install state already up to date` overall — used that instead.
  - `git status --short .claude/` is empty after regeneration (paths ignored, not untracked), confirming the `.gitignore` entries take effect end-to-end.
