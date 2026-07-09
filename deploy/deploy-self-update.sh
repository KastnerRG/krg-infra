#!/usr/bin/env bash
# Control-node self-update — the tail of the PRE-substrate deploy job (Job 1).
#
# krg-deploy runs the deploy, so it cannot switch ITSELF inline: the switch restarts
# the github-runner that IS the running job. And the runner is a hardened sandbox
# (NoNewPrivileges + ProtectSystem=strict), so it can neither escalate (sudo) nor run
# a system switch in its own mount namespace. So the actual switch lives in a
# DECLARATIVE root, host-context systemd unit on krg-deploy
# (systemd.services.krg-deploy-selfupdate in nix/hosts/krg-deploy/default.nix); the
# runner just ASKS PID 1 to start it, authorized by a polkit rule for exactly that
# unit + the krg-admin user — no sudo.
#
# This script:
#   1. BUILDS krg-deploy's target system from the CI-green checkout (never switch).
#   2. TESTS whether it differs from the running system.
#   3. If it does, TRIGGERS the declarative switch unit (`systemctl start --no-block`).
#      That unit delays ~45s (so this job finishes + reports first), stops the runner,
#      switches, and restarts the runner — detached from this job.
#
# The rest of the deploy resumes in a LATER job (deploy-post) gated on the external
# watcher deploy/await-self-update.sh confirming the control node came back.
#
# Outputs (to $GITHUB_OUTPUT, consumed by the workflow):
#   target=<store path>        the built krg-deploy toplevel (deploy-post verifies it)
#   selfupdate=scheduled|skipped
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

HOST=krg-deploy
SELFUPDATE_UNIT=krg-deploy-selfupdate.service

# systemctl: the github-runner service runs with a curated PATH (its extraPackages)
# that doesn't include systemctl, and on NixOS it lives under /run/current-system/sw/bin.
# Resolve it explicitly, preferring PATH (a manual/interactive run) and falling back
# to the system path (the runner). No sudo — a polkit rule authorizes the start.
SYSTEMCTL=systemctl
command -v "$SYSTEMCTL" >/dev/null 2>&1 || SYSTEMCTL=/run/current-system/sw/bin/systemctl

emit() { [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s\n' "$1" >>"$GITHUB_OUTPUT"; return 0; }

echo "::group::build krg-deploy system (self-update check)"
# Build (never switch) the control node's own config from the CI-green checkout.
# krg-deploy IS this host, so build locally — no --target-host/--build-host.
nix build "${FLAKE}#nixosConfigurations.${HOST}.config.system.build.toplevel" \
  --out-link /tmp/krg-deploy-system
target="$(readlink -f /tmp/krg-deploy-system)"
current="$(readlink -f /run/current-system)"
emit "target=${target}"
echo "target : ${target}"
echo "current: ${current}"
printf '\n::endgroup::\n'

if [[ "$target" == "$current" ]]; then
  echo "krg-deploy already at the target generation — no self-update needed."
  emit "selfupdate=skipped"
  exit 0
fi

echo "::group::trigger detached control-node self-update"
# The switch unit must already be present (it's declarative — bootstrapped onto
# krg-deploy by a prior autoUpgrade / manual switch). Fail with a clear message
# rather than an opaque "Unit not found" if this is the pre-bootstrap window.
if ! "$SYSTEMCTL" cat "$SELFUPDATE_UNIT" >/dev/null 2>&1; then
  echo "FATAL: ${SELFUPDATE_UNIT} is not present on krg-deploy."
  echo "       The self-update unit is declarative (nix/hosts/krg-deploy/default.nix) and"
  echo "       must be bootstrapped onto the control node once — via the nightly"
  echo "       system.autoUpgrade or a manual 'nixos-rebuild switch' — before the push"
  echo "       path can trigger it. See deploy/README.md."
  exit 1
fi

# Ask PID 1 to start the root switch unit (polkit-authorized for krg-admin; no sudo).
# --no-block: return immediately so THIS job finishes and reports success before the
# unit's delay elapses and it takes the runner offline.
"$SYSTEMCTL" start --no-block "$SELFUPDATE_UNIT"
echo "triggered ${SELFUPDATE_UNIT} — it will switch krg-deploy to ${target} after a short delay."
echo "the deploy resumes once deploy/await-self-update.sh sees the runner return."
emit "selfupdate=scheduled"
printf '\n::endgroup::\n'
