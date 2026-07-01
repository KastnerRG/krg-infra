#!/usr/bin/env bash
# Control-node self-update verification — the head of the POST-substrate deploy job
# (Job 3), on krg-deploy's runner after it has returned.
#
# The self-update (scheduled by deploy/deploy-self-update.sh) applies in a DETACHED
# unit that cannot fail the job that scheduled it, and the external watcher only
# proves the runner came BACK — not that it came back on the RIGHT generation. So
# this is the safety net: if the running system isn't the target that CI built and
# the pre-substrate job tested, fail loudly rather than deploying the whole fleet
# from a control node that silently didn't update.
set -euo pipefail

target="${DEPLOY_SELF_TARGET:?DEPLOY_SELF_TARGET (the built krg-deploy toplevel) must be set}"
current="$(readlink -f /run/current-system)"

echo "::group::control-node self-update status"
if [[ -r /var/lib/krg/selfupdate.status ]]; then
  echo "status : $(cat /var/lib/krg/selfupdate.status)"
else
  echo "status : (no self-update ran — control node was already current)"
fi
echo "target : ${target}"
echo "current: ${current}"
printf '\n::endgroup::\n'

if [[ "$current" != "$target" ]]; then
  echo "FATAL: krg-deploy is running ${current}, not the target ${target}."
  echo "       The scheduled self-update did not take — refusing to deploy the fleet"
  echo "       from a stale control node. Inspect on-box:"
  echo "         journalctl -u krg-deploy-selfupdate.service"
  echo "         cat /var/lib/krg/selfupdate.status"
  exit 1
fi
echo "OK: control node is running the target generation — resuming the deploy."
