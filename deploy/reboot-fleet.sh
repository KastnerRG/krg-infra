#!/usr/bin/env bash
# Reboot the fleet from the control node (krg-deploy).
#
# This is the push-button counterpart to deploy-nixos.sh: same fleet identity
# (the control node's SSH key + sudoNoPassword/NOPASSWD on every host), same
# strict-host-key SSH policy. It does NOT build or switch; it schedules a reboot
# on each host and confirms the box actually came back. Wired to the manual
# "Reboot fleet" workflow (.github/workflows/reboot-fleet.yml).
#
# Targets:
#   * the provisioned NixOS hosts (mirrors deploy-nixos.sh), AND
#   * the e4e-nas Synology DSM appliance (e4e-admin / its own IP — same control-
#     node key, NOPASSWD sudo; rebooted with plain `sudo reboot` since DSM has no
#     systemd-run).
#
# DELIBERATELY EXCLUDED (for now — tracked in #181):
#   * krg-deploy — it runs THIS job; rebooting it would kill the runner mid-reboot.
#   * fabricant  — the Proxmox hypervisor hosting the VMs (ansible layer);
#                  rebooting it drops every guest at once. Out of scope here.
# Both need a safe out-of-band path before they can be added.
#
# The reachable NixOS host list is kept in lock-step with deploy-nixos.sh — if you
# add or rename a host there, mirror it here.
set -euo pipefail

# Default remote admin (NixOS hosts). Per-host exceptions in USER_OVERRIDE below.
ADMIN="${DEPLOY_ADMIN:-krg-admin}"

# host -> ssh address. NixOS hosts use FQDNs (mirrors deploy-nixos.sh); the NAS
# uses the documented static IP (matches ansible/synology/inventory.yml).
declare -A ADDR=(
  [krg-vault]=krg-vault.ucsd.edu
  [krg-ldap]=krg-ldap.ucsd.edu
  [krg-prod]=krg-prod.ucsd.edu
  [waiter]=waiter.ucsd.edu
  [kastner-ml]=kastner-ml.ucsd.edu
  [e4e-prod]=e4e-prod.ucsd.edu
  [krg-nat]=krg-nat.ucsd.edu
  [e4e-nas]=132.239.17.124
)
# Per-host remote user (default ADMIN). kastner-ml, e4e-prod and e4e-nas are E4E
# hosts → e4e-admin slot; the control node's key is authorized there too (same key,
# see deploy-ansible.sh / nix/keys/admins.json).
declare -A USER_OVERRIDE=(
  [kastner-ml]=e4e-admin
  [e4e-prod]=e4e-admin
  [e4e-nas]=e4e-admin
)
# Reboot command, run over SSH with sudo (every host has passwordless sudo for the
# admin). NixOS default: schedule via a transient timer so the reboot fires AFTER
# ssh returns, giving a clean exit code. DSM (e4e-nas) has no systemd-run, so it
# uses plain `sudo reboot`, which severs the connection — tolerated below, since
# the boot_id check is the real proof either way.
DEFAULT_REBOOT_CMD='sudo systemd-run --on-active=3 --timer-property=AccuracySec=100ms --unit=krg-reboot-action systemctl reboot'
declare -A REBOOT_CMD_OVERRIDE=(
  [e4e-nas]='sudo reboot'
)

# Reboot order. Sequential, one host fully back before the next, so the fleet is
# never all-down at once and the log shows exactly where a failure happened. The
# NAS goes last (slowest to reboot, least coupled to the others' reachability).
ORDER=(krg-vault krg-ldap krg-prod e4e-prod krg-nat waiter kastner-ml e4e-nas)

# Optional args restrict the run to a subset, given as a comma- and/or
# space-separated list of HOSTNAMES (e.g. `reboot-fleet.sh waiter,krg-prod` or
# `reboot-fleet.sh waiter krg-prod`). Empty tokens are ignored, so an unset
# workflow input passed through as one blank arg falls back to the full fleet.
if [[ $# -gt 0 ]]; then
  IFS=', ' read -r -a requested <<<"$*"
  selected=()
  for h in "${requested[@]}"; do
    [[ -z "$h" ]] && continue
    if [[ -z "${ADDR[$h]:-}" ]]; then
      echo "FATAL: unknown host '$h' (known: ${!ADDR[*]})"
      exit 1
    fi
    selected+=("$h")
  done
  [[ ${#selected[@]} -gt 0 ]] && ORDER=("${selected[@]}")
fi

DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/var/lib/krg-admin/.ssh/id_ed25519}"
# Strict host-key checking by default (same policy as deploy-nixos.sh). For
# first-time bring-up only, DEPLOY_SSH_ACCEPT_NEW=true falls back to TOFU.
hostkey="yes"
[[ "${DEPLOY_SSH_ACCEPT_NEW:-false}" == "true" ]] && hostkey="accept-new"
sshopts=(-o "StrictHostKeyChecking=${hostkey}" -o BatchMode=yes -o ConnectTimeout=15)
[[ -f "$DEPLOY_SSH_KEY" ]] && sshopts=(-i "$DEPLOY_SSH_KEY" "${sshopts[@]}")

# How long to wait for a host to come back after the reboot, and how often to poll.
# Generous by default — DSM and waiter (ZFS + impermanence) both boot slowly.
REBOOT_WAIT_TIMEOUT="${REBOOT_WAIT_TIMEOUT:-900}"
REBOOT_POLL_INTERVAL="${REBOOT_POLL_INTERVAL:-10}"

# The kernel boot_id changes on every boot — capturing it before the reboot and
# watching for it to CHANGE is how we prove the host actually rebooted (rather
# than the reboot silently failing and SSH never dropping). Present on any modern
# Linux kernel, DSM included.
boot_id() {
  ssh "${sshopts[@]}" "$1" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

reboot_host() {
  local host="$1" target="$2" cmd="$3" before after waited=0 issue_out
  before="$(boot_id "$target")"
  if [[ -z "$before" ]]; then
    echo "FAILED: ${host} — unreachable before reboot (cannot read boot_id)"
    return 1
  fi

  # Issue the reboot. Tolerate a non-zero exit: `sudo reboot` severs the SSH
  # connection (ssh exits 255) even on success, so the boot_id change below — not
  # this exit code — is the source of truth. Capture output to surface on timeout.
  # $cmd is an in-script constant; expanding it client-side is intended (SC2029).
  # shellcheck disable=SC2029
  issue_out="$(ssh "${sshopts[@]}" "$target" "$cmd" 2>&1)" || true
  echo "${host}: reboot issued (boot_id ${before}); waiting up to ${REBOOT_WAIT_TIMEOUT}s for it to come back…"

  while (( waited < REBOOT_WAIT_TIMEOUT )); do
    sleep "$REBOOT_POLL_INTERVAL"
    waited=$(( waited + REBOOT_POLL_INTERVAL ))
    after="$(boot_id "$target")"
    # Empty => still down/rebooting. Same id => hasn't gone down yet. Different
    # id => it rebooted and SSH is back up.
    if [[ -n "$after" && "$after" != "$before" ]]; then
      echo "OK: ${host} — back up after ~${waited}s (boot_id ${after})"
      return 0
    fi
  done

  echo "FAILED: ${host} — did not come back within ${REBOOT_WAIT_TIMEOUT}s"
  [[ -n "$issue_out" ]] && echo "  reboot-command output was: ${issue_out}"
  return 1
}

# Fail-fast and sequential: if a host doesn't come back, stop rather than reboot
# the rest of the fleet on top of an already-broken host.
for host in "${ORDER[@]}"; do
  target="${USER_OVERRIDE[$host]:-$ADMIN}@${ADDR[$host]}"
  cmd="${REBOOT_CMD_OVERRIDE[$host]:-$DEFAULT_REBOOT_CMD}"
  echo "::group::reboot ${host} (${target})"
  if ! reboot_host "$host" "$target" "$cmd"; then
    echo "::endgroup::"
    echo "Stopping — ${host} did not return; remaining hosts not rebooted."
    exit 1
  fi
  echo "::endgroup::"
done

echo "All requested hosts rebooted and back up: ${ORDER[*]}"
