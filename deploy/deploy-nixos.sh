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
ORDER=(krg-vault krg-ldap krg-prod e4e-prod waiter)

# host -> ssh address. krg-ldap has no DNS `domain` set (addressed by IP); waiter
# is addressed by IP per the runbooks (no host DNS). The rest resolve by FQDN.
declare -A ADDR=(
  [krg-vault]=krg-vault.ucsd.edu
  [krg-ldap]=137.110.161.109
  [krg-prod]=krg-prod.ucsd.edu
  [e4e-prod]=e4e-prod.ucsd.edu
  [waiter]=137.110.161.67
)

DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/var/lib/krg-admin/.ssh/id_ed25519}"
sshopts="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"
[[ -f "$DEPLOY_SSH_KEY" ]] && sshopts="-i ${DEPLOY_SSH_KEY} ${sshopts}"
export NIX_SSHOPTS="${NIX_SSHOPTS:-$sshopts}"

rc=0
for host in "${ORDER[@]}"; do
  target="${ADMIN}@${ADDR[$host]}"
  echo "::group::nixos-rebuild switch ${host} (${target})"
  if nixos-rebuild switch \
        --flake "${FLAKE}#${host}" \
        --target-host "${target}" \
        --build-host  "${target}" \
        --sudo; then
    echo "OK: ${host}"
  else
    echo "FAILED: ${host}"
    rc=1
  fi
  echo "::endgroup::"
done

exit "$rc"
