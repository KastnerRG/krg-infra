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

# ── OEC (campus-mandated Qualys Cloud Agent + Trellix HX/xagt) ───────────────
# These agents are mandatory on EVERY host. The credentialed installer archive
# (live ActivationId/CustomerId — gitignored, .secrets/ is too) is staged
# out-of-band on the control node; we scp it to each host's runtime path BEFORE
# the rebuild so that switch's oec-install oneshot enrolls on the SAME run
# (modules/security/oec-qualys-trellix.nix gates the oneshot on this path), then
# verify both daemons came up afterwards. A missing archive is fatal — we never
# deploy a silently-unhardened host. (Same path/policy as the Ansible layer.)
OEC_INSTALLER="${OEC_INSTALLER:-/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz}"
OEC_DEST="/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz"
if [[ ! -r "$OEC_INSTALLER" ]]; then
  echo "FATAL: OEC installer not readable on the control node: $OEC_INSTALLER"
  echo "       Stage it out-of-band (see deploy/README.md) — hosts cannot be hardened without it."
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
  scp $sshopts "$OEC_INSTALLER" "${target}:/tmp/oec-installer.tgz" \
    && ssh $sshopts "$target" "
        set -e
        sudo install -d -m 0700 -o root -g root /var/lib/krg/oec
        sudo install -m 0600 -o root -g root /tmp/oec-installer.tgz '${OEC_DEST}'
        rm -f /tmp/oec-installer.tgz
      "
}

# Both security daemons must be active after the rebuild. A host where either is
# down fails the deploy (campus-mandated; no half-hardened fleet).
verify_oec() {
  local target="$1" host="$2"
  if ssh $sshopts "$target" 'systemctl is-active --quiet qualys-cloud-agent && systemctl is-active --quiet xagt'; then
    echo "OK: ${host} — qualys-cloud-agent + xagt active"
    return 0
  fi
  echo "FAILED: ${host} — OEC security daemons not both active:"
  ssh $sshopts "$target" 'systemctl is-active qualys-cloud-agent xagt; true' || true
  return 1
}

# krg-deploy verifies ITSELF, locally (no ssh, no rebuild). It's excluded from the
# rebuild loop below — a self-switch would restart this very github-runner mid-job
# — and enrolls instead via its nightly autoUpgrade (which points oec-install at
# the archive the control node already holds; see nix/hosts/krg-deploy). This is
# verify-only: if its daemons aren't up yet (e.g. before the first autoUpgrade has
# enrolled it), the deploy fails like any other host — bootstrap with a one-off
# `sudo nixos-rebuild switch --flake ./nix#krg-deploy` if needed.
verify_oec_local() {
  if systemctl is-active --quiet qualys-cloud-agent && systemctl is-active --quiet xagt; then
    echo "OK: krg-deploy (local) — qualys-cloud-agent + xagt active"
    return 0
  fi
  echo "FAILED: krg-deploy (local) — OEC security daemons not both active:"
  systemctl is-active qualys-cloud-agent xagt || true
  return 1
}

# Fail-fast: stop on the first failed host. Order is dependency-first (vault/AD
# before the services that use them), so a failure early means the dependents
# would be deploying against a broken base — don't.
for host in "${ORDER[@]}"; do
  target="${ADMIN}@${ADDR[$host]}"
  echo "::group::nixos-rebuild switch ${host} (${target})"
  # Stage the OEC archive BEFORE the switch so this rebuild's oec-install
  # oneshot finds it and enrolls on the same run.
  if ! stage_oec "$target"; then
    echo "FAILED: ${host} — could not stage OEC installer; stopping"
    echo "::endgroup::"
    exit 1
  fi
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

# ── Verify the campus-mandated security daemons on every host ────────────────
# Checked across ALL hosts (not fail-fast) so the log shows every offender, then
# the deploy fails if any host is missing a daemon. Enrollment can lag the switch
# (oec-install runs after network-online), so a host that just enrolled should be
# active by the time the whole fleet has rebuilt.
echo "::group::verify OEC security daemons (qualys-cloud-agent + xagt)"
oec_failed=0
for host in "${ORDER[@]}"; do
  target="${ADMIN}@${ADDR[$host]}"
  verify_oec "$target" "$host" || oec_failed=1
done
# ...plus the control node itself (excluded from the rebuild loop above).
verify_oec_local || oec_failed=1
echo "::endgroup::"
if [[ "$oec_failed" -ne 0 ]]; then
  echo "FAILED: OEC security daemons not running on one or more hosts — deploy considered failed"
  exit 1
fi
