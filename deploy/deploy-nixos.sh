#!/usr/bin/env bash
# Deploy every NixOS host in the flake from the control node (krg-deploy).
#
# Activation is non-interactive because the break-glass admin (krg-admin) has
# sudoNoPassword on every host (nix/users/admin.nix), so `nixos-rebuild --sudo`
# needs no password prompt. Each host BUILDS ITS OWN config (--build-host =
# --target-host) so krg-deploy (a small VM) never has to build waiter's
# NVIDIA/CUDA closure or copy gigabytes around — it only evaluates + orchestrates.
#
# krg-deploy ITSELF is intentionally excluded: it runs this deploy, and a
# self-switch can restart the github-runner service mid-job. krg-deploy stays
# current via the nightly system.autoUpgrade in nix/profiles/base.nix.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE="${REPO_ROOT}/nix"
ADMIN="${DEPLOY_ADMIN:-krg-admin}"

# Deploy order: dependencies first (vault/AD before the services that use them).
# e4e-prod is defined in the flake but NOT provisioned yet — omitted until the host
# exists (deploying it would fail at SSH). Re-add it here + in ADDR when it's up.
ORDER=(krg-vault krg-ldap krg-prod waiter)

# host -> ssh address. Fully-qualified DNS names only — never IPs (DNS is the stable
# handle; IPs may change). Names are final per the machine-rename plan (#128).
declare -A ADDR=(
  [krg-vault]=krg-vault.ucsd.edu
  [krg-ldap]=krg-ldap.ucsd.edu
  [krg-prod]=krg-prod.ucsd.edu
  [waiter]=waiter.ucsd.edu
  # [e4e-prod]=e4e-prod.ucsd.edu   # not provisioned yet — re-add to ORDER when it exists
)

DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/var/lib/krg-admin/.ssh/id_ed25519}"
# Strict host-key checking by default (matches ansible.cfg host_key_checking=True):
# krg-deploy's known_hosts must be provisioned out-of-band with the fleet's host
# keys. For FIRST-TIME bring-up only, DEPLOY_SSH_ACCEPT_NEW=true falls back to
# trust-on-first-use (accept-new). Never lower this just to unblock a routine run.
hostkey="yes"
[[ "${DEPLOY_SSH_ACCEPT_NEW:-false}" == "true" ]] && hostkey="accept-new"
sshopts="-o StrictHostKeyChecking=${hostkey} -o BatchMode=yes -o ConnectTimeout=15"
[[ -f "$DEPLOY_SSH_KEY" ]] && sshopts="-i ${DEPLOY_SSH_KEY} ${sshopts}"
export NIX_SSHOPTS="${NIX_SSHOPTS:-$sshopts}"

# Fail-fast: stop on the first failed host. Order is dependency-first (vault/AD
# before the services that use them), so a failure early means the dependents
# would be deploying against a broken base — don't.
for host in "${ORDER[@]}"; do
  target="${ADMIN}@${ADDR[$host]}"
  echo "::group::nixos-rebuild switch ${host} (${target})"
  if ! nixos-rebuild switch \
        --flake "${FLAKE}#${host}" \
        --target-host "${target}" \
        --build-host  "${target}" \
        --sudo; then
    echo "FAILED: ${host} — stopping; remaining hosts not deployed"
    echo "::endgroup::"
    exit 1
  fi
  echo "OK: ${host}"
  echo "::endgroup::"
done
