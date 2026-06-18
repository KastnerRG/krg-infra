#!/usr/bin/env bash
# Phase 4 of the phased deploy (ADR 0011): the SINGLE verification phase, run
# AFTER every layer has converged, for the whole fleet at once. Health/membership
# gates live ONLY here — never mid-converge — so a gate can't fail before the
# stage that would satisfy it has run (the cross-layer deadlock ADR 0011 fixes:
# e.g. the AD `adcli testjoin` gate must run after krg-ldap's firewall lands, not
# inside the earlier Ansible stage that runs before it).
#
# Checks, all COLLECTED (not fail-fast) so the log shows EVERY offender, then a
# single non-zero exit if anything failed:
#   1. OEC (Qualys + Trellix) daemons active on every NixOS host + krg-deploy.
#   2. AD machine-keytab join (`adcli testjoin`) on every NixOS host CONFIGURED as
#      a domain member (krg.adClient.enable), + krg-deploy.
#   3. AD machine-keytab join on the Proxmox hosts (Ansible layer / fabricant) —
#      the gate deploy-ansible.sh deliberately runs in warn-mode mid-converge.
#
# Read-only: no rebuild, no OEC archive needed. Safe to re-run any time. Mirrors
# the OEC + adcli-testjoin checks both layers already know how to run, just
# relocated to one post-converge phase.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared host map + SSH setup (ORDER, ADDR, target_for, sshopts, FLAKE, ...).
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

# Ansible (for the Proxmox AD check) authenticates with the same deploy key.
[[ -f "$DEPLOY_SSH_KEY" ]] && export ANSIBLE_PRIVATE_KEY_FILE="${ANSIBLE_PRIVATE_KEY_FILE:-$DEPLOY_SSH_KEY}"

# Master switch for the AD checks (both NixOS + Proxmox). Default ON — the fleet is
# joined. Set DEPLOY_VERIFY_AD=false for a FIRST, total bring-up before any host has
# joined, so the verify phase doesn't fail on a not-yet-joined fleet. (Per-NixOS-host
# membership is ALSO gated on krg.adClient.enable below, so off-domain hosts are
# skipped even with the switch on; this is the fleet-wide escape hatch.)
VERIFY_AD="${DEPLOY_VERIFY_AD:-true}"

failed=0

# ── 1. OEC security daemons (every host CONFIGURED to run them) ──────────────
# Both qualys-cloud-agent + xagt must be active. Enrollment can lag the switch
# (oec-install runs after network-online), so by the time the whole fleet has
# rebuilt + this phase runs, a host that just enrolled should be active.
verify_oec() {
  local target="$1" host="$2"
  if ssh "${sshopts[@]}" "$target" 'systemctl is-active --quiet qualys-cloud-agent && systemctl is-active --quiet xagt'; then
    echo "OK: ${host} — qualys-cloud-agent + xagt active"
    return 0
  fi
  echo "FAILED: ${host} — OEC security daemons not both active:"
  ssh "${sshopts[@]}" "$target" 'systemctl is-active qualys-cloud-agent xagt; true' || true
  return 1
}

echo "::group::verify OEC security daemons (qualys-cloud-agent + xagt)"
for host in "${ORDER[@]}"; do
  verify_oec "$(target_for "$host")" "$host" || failed=1
done
# ...plus the control node itself (excluded from the rebuild loop; enrolls via its
# nightly autoUpgrade). Verify locally — no ssh.
if systemctl is-active --quiet qualys-cloud-agent && systemctl is-active --quiet xagt; then
  echo "OK: krg-deploy (local) — qualys-cloud-agent + xagt active"
else
  echo "FAILED: krg-deploy (local) — OEC security daemons not both active:"
  systemctl is-active qualys-cloud-agent xagt || true
  failed=1
fi
printf '\n::endgroup::\n'

# ── 2 + 3. AD domain membership (adcli testjoin) ─────────────────────────────
# `adcli testjoin` authenticates the host's MACHINE keytab against the DC — a LIVE
# check that needs no user/admin/service account and bypasses the SSSD user cache
# (so, unlike a getent, it can't pass on a stale cached entry; it catches a member
# that has silently gone offline from the DC). --domain is load-bearing: without it
# adcli probes the host's DNS domain (ucsd.edu), not the krg.local realm.
if [[ "$VERIFY_AD" == "true" ]]; then
  # --- NixOS members (gated per host on krg.adClient.enable, read from the flake;
  # off-domain hosts are SKIPPED, not failed — a host auto-joins this gate the
  # moment its config flips enable = true). sudo: testjoin reads root-only
  # /etc/krb5.keytab (break-glass admin has sudoNoPassword).
  verify_ad() {
    local target="$1" host="$2"
    if ssh "${sshopts[@]}" "$target" 'sudo adcli testjoin --domain krg.local' >/dev/null 2>&1; then
      echo "OK: ${host} — adcli testjoin validated (live DC member)"
      return 0
    fi
    echo "FAILED: ${host} — krg.adClient.enable=true but 'adcli testjoin --domain krg.local' failed (lost join or DC unreachable)"
    return 1
  }

  echo "::group::verify AD membership — NixOS hosts (adcli testjoin)"
  for host in "${ORDER[@]}"; do
    member="$(nix eval "${FLAKE}#nixosConfigurations.${host}.config.krg.adClient.enable" 2>/dev/null || echo unknown)"
    if [[ "$member" != "true" ]]; then
      echo "SKIP: ${host} — krg.adClient.enable=${member} (off-domain by config)"
      continue
    fi
    verify_ad "$(target_for "$host")" "$host" || failed=1
  done
  # Control node (excluded from the rebuild loop) — verify locally if it's a member,
  # but only as a WARNING, never fatal. krg-deploy is deliberately NOT rebuilt by this
  # deploy (a self-switch would restart the github-runner mid-job); it converges its
  # own AD join via the nightly system.autoUpgrade. So the push deploy CANNOT fix
  # krg-deploy's membership — gating it fatally here would make the deploy un-green for
  # a state this run doesn't own (ADR 0011: don't fail a gate on what the run can't
  # converge). Report it so drift is visible, then let autoUpgrade settle it.
  deploy_member="$(nix eval "${FLAKE}#nixosConfigurations.krg-deploy.config.krg.adClient.enable" 2>/dev/null || echo unknown)"
  if [[ "$deploy_member" == "true" ]]; then
    if sudo adcli testjoin --domain krg.local >/dev/null 2>&1; then
      echo "OK: krg-deploy (local) — adcli testjoin validated (live DC member)"
    else
      echo "WARN: krg-deploy (local) — krg.adClient.enable=true but 'adcli testjoin --domain krg.local' failed."
      echo "      Not fatal: krg-deploy isn't rebuilt by this deploy; it converges via nightly autoUpgrade."
    fi
  else
    echo "SKIP: krg-deploy (local) — krg.adClient.enable=${deploy_member} (off-domain by config)"
  fi
  printf '\n::endgroup::\n'

  # --- Proxmox hosts (Ansible layer / fabricant): the cross-layer gate ADR 0011
  # had deploy-ansible.sh defer out of its converge (it runs BEFORE krg-ldap's AD
  # firewall fix lands). Run the live machine-keytab check ad-hoc against the
  # `proxmox` group — failing if a host has lost its join / can't reach the DC.
  # ansible_user=root over SSH (inventory), so adcli reads the keytab directly.
  # --domain-controller is pinned (matching the ad_client role's join + check): a
  # Debian member's resolver is campus DNS, which doesn't serve the krg.local zone, so
  # adcli's default DNS-SRV discovery fails ("couldn't find usable domain controller")
  # even with the AD ports open — pinning the DC (resolved via the role's /etc/hosts
  # entry) makes testjoin connect directly. krg-ldap.krg.local mirrors the role's
  # ad_dc_host default.
  echo "::group::verify AD membership — Proxmox hosts (adcli testjoin)"
  if ! (
    cd "${REPO_ROOT}/ansible"
    ansible proxmox -m ansible.builtin.command -a 'adcli testjoin --domain krg.local --domain-controller krg-ldap.krg.local'
  ); then
    echo "FAILED: one or more Proxmox hosts failed 'adcli testjoin' (lost join or DC unreachable)"
    failed=1
  fi
  printf '\n::endgroup::\n'
else
  echo "skip AD verification: DEPLOY_VERIFY_AD=${VERIFY_AD} (first bring-up escape hatch)"
fi

if [[ "$failed" -ne 0 ]]; then
  echo "FAILED: fleet verification found problems (see the failures above)"
  exit 1
fi
echo "OK: fleet verification passed (OEC + AD membership)"
