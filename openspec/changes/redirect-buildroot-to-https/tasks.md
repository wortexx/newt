# Redirect buildroot to HTTPS (change `redirect-buildroot-to-https`) — tasks

Tags:

- **[edit]**: plain file editing, checked locally (`actionlint` in Docker, and the redirect check
  run inside `ghcr.io/wortexx/newt-eda:dev`).
- **[gh]**: a PR and its GitHub-hosted fast-lane run. No VM time.

No task needs synthesis, P&R or the Azure VM.

## 1. Redirect and check in the workflows (D1, D3)

- [x] 1.1 **[edit]** `ci.yml`: add a top-level `env:` block with `GIT_CONFIG_COUNT: '1'`,
  `GIT_CONFIG_KEY_0: url.https://gitlab.com/buildroot.org/buildroot.git.insteadOf` and
  `GIT_CONFIG_VALUE_0: git://git.buildroot.net/buildroot`, with a comment naming this change and
  the 2026-10-06/07 outages. Add the D3 check as the first step after checkout in each of `lint`,
  `sw`, `sim-unit`, `sim-soc` and `synth-coproc`. Verify: `actionlint` is clean, and
  `grep -c 'ls-remote --get-url' .github/workflows/ci.yml` is 5. — done: 5 checks. `actionlint` reports only 2 info-level shellcheck findings (SC2013, SC2329) in `lint`'s `verilator --lint-only` script, the same 2 that `main` already has at line 115. This change adds none.
- [x] 1.2 **[edit]** `synth.yml`: the same `env:` block and check, the check before
  `make ig-hw-all`. Verify: `actionlint` is clean. — done, `actionlint` clean.
- [x] 1.3 **[edit]** `pnr.yml`: the three variables added to the existing workflow-level `env:`
  block, and the check before `make ig-hw-all` in the `pnr` job. Verify: `actionlint` is clean,
  and no job other than the dependency-checkout ones gains the check. — done, `actionlint` clean. The check is in `pnr` only. `start`, `restore-checkpoints`, `upload-checkpoints` and `stop` do no dependency checkout.
- [x] 1.4 **[edit]** Check the redirect where it runs:
  `docker run --rm -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=… -e GIT_CONFIG_VALUE_0=… ghcr.io/wortexx/newt-eda:dev git ls-remote --get-url git://git.buildroot.net/buildroot`
  prints the GitLab URL. Then check the D3 step itself: its shell snippet exits non-zero without
  the variables and zero with them. Verify: both outcomes recorded here. — done 2026-10-07 in `newt-eda:dev` (git 2.43). With the variables, the step prints `buildroot redirected to https://gitlab.com/buildroot.org/buildroot.git` and exits 0. Without them, it prints `::error::buildroot is not redirected to HTTPS (got git://git.buildroot.net/buildroot) …` and exits 1. The snippet was taken verbatim from `ci.yml`.

## 2. Comments and docs (D4)

- [x] 2.1 **[edit]** Update the `retry` comments in `ci.yml` (the `lint` header comment and the
  ones that point at it), `synth.yml` and `pnr.yml`. Buildroot is now redirected, and the retry
  remains for transient faults on the other remotes. Verify: `git grep -n 'buildroot' .github`
  shows no comment that still names buildroot as a live cause without mentioning the redirect. — done: `lint`'s header comment, `sw`'s pointer, `synth.yml` and `pnr.yml`. Every remaining `buildroot` mention in `.github/` is in or next to a redirect comment.
- [x] 2.2 **[edit]** `AGENTS.md` tool setup: one short paragraph with
  `git config --global url.https://gitlab.com/buildroot.org/buildroot.git.insteadOf git://git.buildroot.net/buildroot`
  for local and `use-docker.sh` users, and why. Verify: the command in the doc, run in a scratch
  `HOME`, makes `git ls-remote --get-url` print the GitLab URL. — done: a new `### Buildroot clone (Docker and local)` subsection under Tool setup. The command, extracted from the doc and run with a scratch `HOME`, makes `--get-url` print the GitLab URL.
- [x] 2.3 **[edit]** `docs/infra-plan.md`: a new optional phase for workaround B, the durable fix.
  The Cheshire fork's next tag, `newt.3`, drops the unused `sw/deps/cva6-sdk` submodule, or points
  it at a `cva6-sdk` fork whose `buildroot` URL is HTTPS. It is paired with Phase 16's planned
  crt0/bootrom fix, which is also aimed at `newt.3`. Cost: one re-synthesis, since `Bender.lock`
  is a synth cache key input, after which no earlier checkpoint can be resumed. Also faster
  checkouts (no buildroot, u-boot, opensbi, …). Add it to the phase-ordering list, and a pointer
  from Phase 0's "Still open" note and Phase 16's fix item. Verify: the phase states it is
  optional, what it removes, its cost, and its tie to Phase 16 and to this change (A). — done: Phase 18 (optional), placed before Phase 17. Pointers added in the phase-ordering list, Phase 0's "Still open" note and Phase 16's fork-fix item.

## 3. Land it

- [ ] 3.1 **[gh]** Open a PR. Verify: all five fast-lane jobs pass, and each job's log shows the
  check step passing before the dependency checkout. If `git.buildroot.net` happens to be down
  at the time, a green run also proves the scenario "Legacy buildroot server unreachable".
- [ ] 3.2 **[gh]** After merge, rebase PR #64 (`grt-repair-results`) onto `main` so its fast lane
  runs with the redirect. Verify: #64's fast lane is green.
