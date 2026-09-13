#!/usr/bin/env bash
#
# Copyright 2026 the newt project authors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Brings a runner host to the state the CI lanes need - docs/infra-plan.md
# Phase 6, design D3/D4. One artifact, three entry points:
#
#   1. cloud-init on a fresh VM (customData, see cloud-init.yaml)
#   2. az vm run-command invoke, to converge the existing VM
#   3. by hand over SSH
#
# Every step is guarded, so a re-run on a satisfied host changes nothing and
# says so. Registration is skipped unless RUNNER_NAME is set AND the runner is
# not already configured, so converging the live VM can never re-register it.
#
# Secrets: the PAT is read from Key Vault into a shell variable and never
# written to disk, logged, or passed on a command line. Do not add `set -x`.
#
# Environment:
#   RUNNER_USER     host user owning the runner service (default: newt)
#   RUNNER_NAME     runner name to register; empty means skip registration
#   RUNNER_LABELS   comma-separated labels (default: self-hosted-synth)
#   GITHUB_REPO     owner/repo to register against (default: wortexx/newt)
#   KEY_VAULT_NAME  vault holding the registration PAT; required to register
#   PAT_SECRET_NAME secret name (default: github-runner-pat)

set -euo pipefail

RUNNER_USER="${RUNNER_USER:-newt}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted-synth}"
GITHUB_REPO="${GITHUB_REPO:-wortexx/newt}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
PAT_SECRET_NAME="${PAT_SECRET_NAME:-github-runner-pat}"

RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"
NEEDRESTART_CONF="/etc/needrestart/conf.d/99-ci-runner.conf"

log()  { printf '[provision-runner] %s\n' "$*"; }
skip() { printf '[provision-runner] ok (already satisfied): %s\n' "$*"; }
die()  { printf '[provision-runner] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (cloud-init, run-command and sudo all do)"
id "$RUNNER_USER" >/dev/null 2>&1 || die "user ${RUNNER_USER} does not exist"

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    skip "docker is installed"
  else
    log "installing docker via get.docker.com"
    local script
    script="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$script"
    sh "$script"
    rm -f "$script"
    log "docker installed"
  fi

  if id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -qx docker; then
    skip "${RUNNER_USER} is in the docker group"
  else
    log "adding ${RUNNER_USER} to the docker group"
    usermod -aG docker "$RUNNER_USER"
  fi
}

# ---------------------------------------------------------------------------
# 2. Azure CLI - the upload-checkpoints job runs az on the host, outside the
#    EDA container (ci-pnr-lane design D5).
# ---------------------------------------------------------------------------

install_azure_cli() {
  if command -v az >/dev/null 2>&1; then
    skip "azure cli is installed"
    return
  fi
  log "installing azure cli via aka.ms/InstallAzureCLIDeb"
  local script
  script="$(mktemp)"
  curl -fsSL https://aka.ms/InstallAzureCLIDeb -o "$script"
  bash "$script"
  rm -f "$script"
  log "azure cli installed"
}

# ---------------------------------------------------------------------------
# 3. Never let a package upgrade restart the runner underneath a live job.
#    Root-caused in pnr-bringup-8; see the ci-pnr-lane runbook section 3.2.
#    apt-daily.timer stays enabled on purpose - it only refreshes lists.
# ---------------------------------------------------------------------------

disable_auto_upgrades() {
  local state
  # `systemctl is-enabled` prints the state and exits non-zero when a unit is
  # disabled, so the exit code is swallowed with `|| true` rather than `||
  # echo disabled` - the latter appends a second word and the comparison then
  # never matches, re-disabling an already-disabled timer on every run.
  state="$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
  case "$state" in
    disabled|masked|'')
      skip "apt-daily-upgrade.timer is ${state:-absent}"
      ;;
    *)
      log "disabling apt-daily-upgrade.timer (was ${state})"
      systemctl disable --now apt-daily-upgrade.timer
      ;;
  esac
}

write_needrestart_override() {
  local desired
  # shellcheck disable=SC2016  # $nrconf is Perl, read by needrestart - it must stay literal
  desired='$nrconf{override_rc}{qr(^actions\.runner\.)} = 0;
$nrconf{override_rc}{qr(^docker\.)} = 0;
$nrconf{override_rc}{qr(^containerd\.)} = 0;'

  if [ -f "$NEEDRESTART_CONF" ] && [ "$(cat "$NEEDRESTART_CONF")" = "$desired" ]; then
    skip "needrestart override ${NEEDRESTART_CONF} is current"
    return
  fi
  log "writing needrestart override ${NEEDRESTART_CONF}"
  mkdir -p "$(dirname "$NEEDRESTART_CONF")"
  printf '%s\n' "$desired" > "$NEEDRESTART_CONF"
}

# ---------------------------------------------------------------------------
# 4. Actions runner
# ---------------------------------------------------------------------------

install_runner() {
  if [ -x "${RUNNER_DIR}/config.sh" ]; then
    skip "runner is unpacked in ${RUNNER_DIR}"
    return
  fi

  local version tarball url
  version="$(curl -fsS -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/actions/runner/releases/latest \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
  [ -n "$version" ] || die "could not resolve the latest actions/runner release"

  tarball="actions-runner-linux-x64-${version}.tar.gz"
  url="https://github.com/actions/runner/releases/download/v${version}/${tarball}"
  log "installing actions runner ${version}"

  install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"
  curl -fsSL "$url" -o "/tmp/${tarball}"
  tar xzf "/tmp/${tarball}" -C "$RUNNER_DIR"
  rm -f "/tmp/${tarball}"
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"

  if [ -x "${RUNNER_DIR}/bin/installdependencies.sh" ]; then
    "${RUNNER_DIR}/bin/installdependencies.sh"
  fi
}

# Echoes the PAT read from Key Vault via this VM's own managed identity.
#
# Retries, because on a fresh VM this runs seconds after the deployment created
# the role assignment granting this identity access, and Key Vault RBAC takes
# minutes to propagate - a 403 here is the expected first-boot state, not a
# failure. Logs go to stderr so they cannot contaminate the captured value.
fetch_pat_from_vault() {
  local attempt=1 max_attempts=20 imds_token status body
  body="$(mktemp)"
  while [ "$attempt" -le "$max_attempts" ]; do
    imds_token="$(curl -fsS -H 'Metadata: true' \
      'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' \
      2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)"

    if [ -z "$imds_token" ]; then
      status='no-imds-token'
    else
      status="$(curl -sS -o "$body" -w '%{http_code}' \
        -H "Authorization: Bearer ${imds_token}" \
        "https://${KEY_VAULT_NAME}.vault.azure.net/secrets/${PAT_SECRET_NAME}?api-version=7.4" 2>/dev/null || echo curl-failed)"
      if [ "$status" = "200" ]; then
        # Whitespace is stripped deliberately: a PAT contains none, and a stray
        # space or newline picked up when the secret was set would otherwise
        # surface much later as an opaque 401 from the registration-token call.
        python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' < "$body" | tr -d '[:space:]'
        rm -f "$body"
        return 0
      fi
    fi

    log "Key Vault read ${attempt}/${max_attempts} returned ${status}; RBAC propagation lags a fresh deployment, retrying in 15s" >&2
    attempt=$((attempt + 1))
    sleep 15
  done
  rm -f "$body"
  die "could not read ${PAT_SECRET_NAME} from ${KEY_VAULT_NAME} after ${max_attempts} attempts - check this VM has a system-assigned identity and a Key Vault Secrets User assignment on the vault"
}

# Exchanges the PAT for a short-lived registration token. Neither value is
# written to disk.
mint_registration_token() {
  local pat body status
  pat="$(fetch_pat_from_vault)"
  [ -n "$pat" ] || die "secret ${PAT_SECRET_NAME} in ${KEY_VAULT_NAME} is empty"

  body="$(mktemp)"
  status="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${pat}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token")"

  if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    rm -f "$body"
    die "registration-token request returned ${status} - rotate ${PAT_SECRET_NAME} in Key Vault ${KEY_VAULT_NAME} (fine-grained PAT on ${GITHUB_REPO}, Administration: read and write)"
  fi
  if [ "$status" != "201" ]; then
    rm -f "$body"
    die "registration-token request returned ${status}"
  fi

  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' < "$body"
  rm -f "$body"
}

register_runner() {
  if [ -f "${RUNNER_DIR}/.runner" ]; then
    skip "runner is already registered (${RUNNER_DIR}/.runner exists)"
    return
  fi
  if [ -z "$RUNNER_NAME" ]; then
    log "RUNNER_NAME is empty - skipping registration (this is the expected path when converging an existing VM)"
    return
  fi
  [ -n "$KEY_VAULT_NAME" ] || die "KEY_VAULT_NAME is required to register a runner"

  log "registering runner ${RUNNER_NAME} on ${GITHUB_REPO} with labels ${RUNNER_LABELS}"
  local token
  token="$(mint_registration_token)"

  sudo -u "$RUNNER_USER" env RUNNER_ALLOW_RUNASROOT=0 \
    "${RUNNER_DIR}/config.sh" \
      --unattended \
      --replace \
      --url "https://github.com/${GITHUB_REPO}" \
      --token "$token" \
      --name "$RUNNER_NAME" \
      --labels "$RUNNER_LABELS"

  log "installing and starting the runner service"
  ( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start )
  log "runner ${RUNNER_NAME} registered and running"
}

main() {
  log "converging ${HOSTNAME:-this host} for user ${RUNNER_USER}"
  install_docker
  install_azure_cli
  disable_auto_upgrades
  write_needrestart_override
  install_runner
  register_runner
  log "done"
}

main "$@"
