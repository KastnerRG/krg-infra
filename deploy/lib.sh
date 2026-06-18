#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared fleet host map + SSH setup for the NixOS legs of the phased deploy
# (ADR 0011): deploy-nixos.sh REBUILDS hosts, deploy-verify.sh CHECKS them. This
# file is SOURCED, never executed — it keeps the host list, addresses, per-host
# admin overrides and the SSH options in ONE place so adding a host (or changing
# its address / admin) can't drift the rebuild leg out of sync with the verify
# leg. (reboot-fleet.sh keeps its OWN list deliberately — it has a different host
# set: it also reboots the e4e-nas appliance and excludes the control node.)
#
# The caller must set REPO_ROOT before sourcing. Tunables (DEPLOY_ADMIN,
# DEPLOY_SSH_KEY, DEPLOY_SSH_ACCEPT_NEW) are read here so both legs honour them.

# shellcheck disable=SC2034  # FLAKE consumed by sourcing scripts, not here
FLAKE="${REPO_ROOT}/nix"
ADMIN="${DEPLOY_ADMIN:-krg-admin}"

# Deploy/verify order: dependencies first (vault/AD before the services that use
# them); compute boxes (waiter, kastner-ml) last. The phased deploy splits this
# list across phases (foundation vs members) via DEPLOY_NIXOS_HOSTS, but the
# canonical dependency order lives HERE so a rebuild always walks it.
# e4e-prod is defined in the flake but NOT provisioned yet — omitted until the
# host exists (deploying it would fail at SSH). Re-add it here + in ADDR when up.
# shellcheck disable=SC2034  # consumed by sourcing scripts, not here
ORDER=(krg-vault krg-ldap krg-prod waiter kastner-ml)

# host -> ssh address. Fully-qualified DNS names only — never IPs (DNS is the
# stable handle; IPs may change). Names are final per the rename plan (#128).
# shellcheck disable=SC2034  # consumed by sourcing scripts, not here
declare -A ADDR=(
  [krg-vault]=krg-vault.ucsd.edu
  [krg-ldap]=krg-ldap.ucsd.edu
  [krg-prod]=krg-prod.ucsd.edu
  [waiter]=waiter.ucsd.edu
  [kastner-ml]=kastner-ml.ucsd.edu
  # [e4e-prod]=e4e-prod.ucsd.edu   # not provisioned yet — re-add to ORDER when it exists
)

# Per-host remote user (default ADMIN). kastner-ml is E4E hardware → the e4e-admin
# break-glass account (nix/hosts/kastner-ml/default.nix sets krg.adminAccount); the
# control node's deploy key is authorized for both (nix/keys/admins.json) and both
# have sudoNoPassword, so the OEC staging + --sudo rebuild stay non-interactive.
# shellcheck disable=SC2034  # consumed by sourcing scripts, not here
declare -A USER_OVERRIDE=(
  [kastner-ml]=e4e-admin
)

# <host> -> "<user>@<fqdn>"  (default admin unless overridden above)
target_for() { echo "${USER_OVERRIDE[$1]:-$ADMIN}@${ADDR[$1]}"; }

DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/var/lib/krg-admin/.ssh/id_ed25519}"
# Strict host-key checking by default (matches ansible.cfg host_key_checking=True):
# krg-deploy's known_hosts must be provisioned out-of-band with the fleet's host
# keys. For FIRST-TIME bring-up only, DEPLOY_SSH_ACCEPT_NEW=true falls back to
# trust-on-first-use (accept-new). Never lower this just to unblock a routine run.
hostkey="yes"
[[ "${DEPLOY_SSH_ACCEPT_NEW:-false}" == "true" ]] && hostkey="accept-new"
# An array (not a string) so each option is a distinct argv element — passed as
# "${sshopts[@]}" to ssh/scp it never word-splits or globs. NIX_SSHOPTS, which
# nixos-rebuild reads as a single space-separated string, gets the joined form.
# shellcheck disable=SC2034  # sshopts consumed by sourcing scripts, not here
sshopts=(-o "StrictHostKeyChecking=${hostkey}" -o BatchMode=yes -o ConnectTimeout=15)
[[ -f "$DEPLOY_SSH_KEY" ]] && sshopts=(-i "$DEPLOY_SSH_KEY" "${sshopts[@]}")
export NIX_SSHOPTS="${NIX_SSHOPTS:-${sshopts[*]}}"
