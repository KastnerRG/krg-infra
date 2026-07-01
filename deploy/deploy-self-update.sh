#!/usr/bin/env bash
# Control-node self-update — the tail of the PRE-substrate deploy job (Job 1).
#
# krg-deploy runs the deploy, so it cannot switch ITSELF inline: the switch restarts
# the github-runner that IS the running job (that is why deploy/deploy-nixos.sh
# excludes krg-deploy, and why control-node changes historically only landed via the
# nightly autoUpgrade). This closes that gap on the push path:
#
#   1. BUILD krg-deploy's target system from the CI-green checkout (never switch).
#   2. TEST whether it differs from the running system.
#   3. If it does, SCHEDULE the switch in a DETACHED systemd transient unit
#      (systemd-run --on-active) that outlives this job + the runner restart.
#
# The rest of the deploy resumes in a LATER job (deploy-post) gated on the external
# watcher deploy/await-self-update.sh confirming the control node came back — NOT on
# this timer. So the delay just needs to outlast this job reporting success.
#
# Outputs (to $GITHUB_OUTPUT, consumed by the workflow):
#   target=<store path>        the built krg-deploy toplevel (deploy-post verifies it)
#   selfupdate=scheduled|skipped
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

HOST=krg-deploy
SELFSWITCH_SRC="${REPO_ROOT}/deploy/krg-deploy-selfswitch.sh"
SELFSWITCH_DEST=/var/lib/krg/krg-deploy-selfswitch.sh
# Delay before the detached switch fires — long enough for THIS job to finish and
# report success to GitHub before the runner is stopped. The rest of the deploy is
# gated on the external watcher, not this timer, so a generous delay is free.
SELFSWITCH_DELAY="${SELFSWITCH_DELAY:-45s}"

# sudo: this is the FIRST deploy leg to run sudo LOCALLY on the control node (the
# others only sudo on remote hosts via ssh/nixos-rebuild --sudo). The github-runner
# service runs with a curated PATH (its extraPackages) that does NOT include sudo,
# and on NixOS sudo is the setuid wrapper under /run/wrappers/bin — so resolve it
# explicitly. Falls back to that wrapper path when sudo isn't on PATH (the runner),
# and uses PATH sudo for a manual/interactive run.
SUDO=sudo
command -v "$SUDO" >/dev/null 2>&1 || SUDO=/run/wrappers/bin/sudo

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

echo "::group::schedule detached control-node self-update"
# Clear any stale transient unit from a previous run so systemd-run can recreate it.
"$SUDO" systemctl stop krg-deploy-selfupdate.timer krg-deploy-selfupdate.service 2>/dev/null || true
"$SUDO" systemctl reset-failed krg-deploy-selfupdate.timer krg-deploy-selfupdate.service 2>/dev/null || true

# Install the detached switch payload to a STABLE path: the CI checkout is ephemeral
# and may be cleaned before the timer fires, but a systemd unit's ExecStart must
# still exist when it runs.
"$SUDO" install -d -m 0755 -o root -g root /var/lib/krg
"$SUDO" install -m 0755 -o root -g root "$SELFSWITCH_SRC" "$SELFSWITCH_DEST"

# Detached transient timer+service, OWNED BY PID 1 (not the runner's cgroup), so it
# survives the runner restart the switch triggers. TARGET is forwarded via --setenv.
"$SUDO" systemd-run \
  --unit=krg-deploy-selfupdate \
  --on-active="$SELFSWITCH_DELAY" \
  --timer-property=AccuracySec=1s \
  --property=Type=oneshot \
  --setenv=TARGET="$target" \
  "$SELFSWITCH_DEST"

echo "scheduled krg-deploy switch to ${target} in ${SELFSWITCH_DELAY} (unit krg-deploy-selfupdate)."
echo "the deploy resumes once deploy/await-self-update.sh sees the runner return."
emit "selfupdate=scheduled"
printf '\n::endgroup::\n'
