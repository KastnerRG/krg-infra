#!/usr/bin/env bash
# Rebuild NixOS hosts in the flake from the control node (krg-deploy).
#
# Activation is non-interactive because the break-glass admin (krg-admin, or
# e4e-admin on E4E hosts — see USER_OVERRIDE in deploy/lib.sh) has sudoNoPassword
# on every host (nix/users/admin.nix), so `nixos-rebuild --sudo` needs no password
# prompt. The control node's deploy key is authorized for BOTH admin accounts
# (nix/keys/admins.json). Each host BUILDS ITS OWN config (--build-host =
# --target-host) so krg-deploy (a small VM) never has to build waiter's
# NVIDIA/CUDA closure or copy gigabytes around — it only evaluates + orchestrates.
#
# PHASED DEPLOY (ADR 0011): this script REBUILDS only — it does NOT verify. The
# phased pipeline (.github/workflows/deploy.yml) calls it TWICE:
#   • phase 0 (foundation) — DEPLOY_NIXOS_HOSTS="krg-vault krg-ldap", BEFORE Ansible.
#     krg-ldap carries the in-guest AD firewall the Ansible substrate phase depends
#     on (it must open the DC ports to fabricant before fabricant can validate AD),
#     and krg-vault brings up OpenBao. Hoisting them removes the NixOS→Ansible
#     back-edge that no single layer ordering could satisfy.
#   • phase 2 (systems) — DEPLOY_NIXOS_HOSTS="krg-prod waiter kastner-ml", AFTER it.
#     The compute boxes mount /home from the NFS exports the Ansible phase creates.
# OEC + AD membership are checked in the FINAL verify phase (deploy/deploy-verify.sh),
# never here — so a health gate can't deadlock the converge meant to satisfy it.
#
# krg-deploy ITSELF is intentionally excluded (not in ORDER): it runs this deploy,
# and a self-switch can restart the github-runner service mid-job. krg-deploy stays
# current via the nightly system.autoUpgrade in nix/profiles/base.nix.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared host map + SSH setup (ORDER, ADDR, USER_OVERRIDE, target_for, sshopts,
# FLAKE, ADMIN, NIX_SSHOPTS) — also used by deploy-verify.sh; kept in one place.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

# Which hosts to rebuild this invocation. DEPLOY_NIXOS_HOSTS = space-separated
# subset of ORDER (must be known hosts); unset = the full ORDER (a manual, single-
# shot full rebuild). Hosts always rebuild in ORDER (dependency-first) regardless
# of the order they're listed in the env.
declare -A WANT=()
if [[ -n "${DEPLOY_NIXOS_HOSTS:-}" ]]; then
  read -r -a _sel <<< "$DEPLOY_NIXOS_HOSTS"
  for h in "${_sel[@]}"; do
    if [[ -z "${ADDR[$h]:-}" ]]; then
      echo "FATAL: DEPLOY_NIXOS_HOSTS names unknown host '$h' (known: ${!ADDR[*]})"
      exit 2
    fi
    WANT[$h]=1
  done
else
  for h in "${ORDER[@]}"; do WANT[$h]=1; done
fi

# ── OEC (campus-mandated Qualys Cloud Agent + Trellix HX/xagt) ───────────────
# These agents are mandatory on EVERY host. The credentialed installer archive
# (live ActivationId/CustomerId — gitignored, .secrets/ is too) is staged
# out-of-band on the control node; we scp it to each host's runtime path BEFORE
# the rebuild so that switch's oec-install oneshot enrolls on the SAME run
# (modules/security/oec-qualys-trellix.nix gates the oneshot on this path). A
# missing archive is fatal — we never deploy a silently-unhardened host. (Whether
# both daemons actually came up is asserted later, in deploy/deploy-verify.sh.)
OEC_INSTALLER="${OEC_INSTALLER:-/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz}"
OEC_DEST="/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz"
if [[ ! -r "$OEC_INSTALLER" ]]; then
  echo "FATAL: OEC installer not readable on the control node: $OEC_INSTALLER"
  echo "       Stage it out-of-band (see deploy/README.md) — hosts cannot be hardened without it."
  exit 1
fi
# Sanity-check the archive HERE (it's a tar — plain or compressed; tar -tf
# auto-detects) so a corrupt/truncated/wrong-format file fails fast on the
# control node with a clear message, rather than surfacing as an opaque
# oec-install failure mid-rebuild on the first host (which is how the gzip-vs-
# plain-tar mismatch first bit us).
if ! tar -tf "$OEC_INSTALLER" >/dev/null 2>&1; then
  echo "FATAL: OEC installer is not a readable tar archive: $OEC_INSTALLER"
  echo "       Re-stage the vendor archive (it is a tar — plain or gz; corrupt/truncated otherwise)."
  exit 1
fi

# Push the OEC archive to <target> and install it root-owned 0600 at OEC_DEST.
# scp lands it as krg-admin in /tmp, then sudo-installs into the root-owned
# /var/lib/krg/oec (krg-admin can't write there directly); sudoNoPassword
# (nix/users/admin.nix) keeps it non-interactive. Re-pushing identical bytes
# each deploy is harmless — the oneshot's own sentinel makes enrollment one-time.
stage_oec() {
  local target="$1"
  # &&-chained (not two statements): called as `if ! stage_oec`, which suspends
  # set -e inside the function, so a failed scp must short-circuit explicitly.
  # OEC_DEST is a fixed in-script constant, so expanding it client-side (rather
  # than on the remote) is intended — silence SC2029 for this command.
  # shellcheck disable=SC2029
  scp "${sshopts[@]}" "$OEC_INSTALLER" "${target}:/tmp/oec-installer.tgz" \
    && ssh "${sshopts[@]}" "$target" "
        set -e
        sudo install -d -m 0700 -o root -g root /var/lib/krg/oec
        sudo install -m 0600 -o root -g root /tmp/oec-installer.tgz '${OEC_DEST}'
        rm -f /tmp/oec-installer.tgz
      "
}

# Fail-fast: stop on the first failed host. Order is dependency-first (vault/AD
# before the services that use them), so a failure early means the dependents
# would be deploying against a broken base — don't.
for host in "${ORDER[@]}"; do
  [[ -n "${WANT[$host]:-}" ]] || continue
  target="$(target_for "$host")"
  echo "::group::nixos-rebuild switch ${host} (${target})"
  # Stage the OEC archive BEFORE the switch so this rebuild's oec-install
  # oneshot finds it and enrolls on the same run.
  if ! stage_oec "$target"; then
    echo "FAILED: ${host} — could not stage OEC installer; stopping"
    printf '\n::endgroup::\n'
    exit 1
  fi
  if ! nixos-rebuild switch \
        --flake "${FLAKE}#${host}" \
        --target-host "${target}" \
        --build-host  "${target}" \
        --sudo; then
    echo "FAILED: ${host} — stopping; remaining hosts not deployed"
    printf '\n::endgroup::\n'
    exit 1
  fi
  echo "OK: ${host}"
  printf '\n::endgroup::\n'
done
