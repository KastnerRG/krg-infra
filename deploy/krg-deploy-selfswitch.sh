#!/usr/bin/env bash
# Detached control-node self-switch. NOT run inline in the deploy job — a
# `nixos-rebuild switch` on krg-deploy restarts the github-runner that IS the job,
# which would kill it mid-switch. Instead deploy/deploy-self-update.sh installs this
# to a stable path and schedules it via `systemd-run --on-active`, so it runs in a
# transient unit owned by PID 1 that OUTLIVES the runner restart.
#
# TARGET (the pre-built, CI-green krg-deploy system toplevel) is forwarded by
# systemd-run --setenv. This is exactly what `nixos-rebuild switch` does under the
# hood, but against the already-built store path — no re-eval, no dependence on the
# ephemeral CI checkout (which may be cleaned before the timer fires).
#
# SWITCH-ONLY — never reboots the control node (deploy design decision): a change
# that needs a reboot (kernel/initrd) activates but the new kernel waits for a
# manual/nightly reboot rather than dropping the control node unattended.
set -uo pipefail

STATUS=/var/lib/krg/selfupdate.status
RUNNER=github-runner-krg-deploy.service
log() { printf '%s %s\n' "$(date -Is)" "$*"; }

fail() {
  log "FAILED: $*"
  printf 'failed %s :: %s\n' "${TARGET:-<unset>}" "$*" >"$STATUS" 2>/dev/null || true
  # Always try to bring the runner back so the post-substrate job (and the operator)
  # can reach the deploy pipeline to diagnose, even on a failed switch.
  systemctl start "$RUNNER" || true
  exit 1
}

[[ -n "${TARGET:-}" && -e "$TARGET" ]] || fail "TARGET missing or not in the store: ${TARGET:-<unset>}"

printf 'running %s\n' "$TARGET" >"$STATUS"

# Take the runner offline for the WHOLE switch so the external watcher
# (deploy/await-self-update.sh) sees a clean offline->online transition. A no-op or
# runner-unit-unchanged switch would otherwise never restart it, and the watcher
# would time out waiting to observe the box go down.
systemctl stop "$RUNNER" || true

nix-env -p /nix/var/nix/profiles/system --set "$TARGET" || fail "nix-env --set"
"$TARGET/bin/switch-to-configuration" switch || fail "switch-to-configuration switch"

# Bring the runner back on the NEW code (idempotent if the switch already started it).
systemctl start "$RUNNER" || fail "runner restart after switch"

printf 'ok %s\n' "$TARGET" >"$STATUS"
log "OK: krg-deploy switched to $TARGET"
