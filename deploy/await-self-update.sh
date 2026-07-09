#!/usr/bin/env bash
# External watcher ("cloud machine") for the control-node self-update — runs on a
# GitHub-HOSTED runner (Job 2), because the self-hosted runner on krg-deploy is the
# very thing going down during the switch and cannot watch itself.
#
# It CANNOT ping krg-deploy directly: the control node's firewall admits only
# UCSD/ops sources, and a GitHub-hosted runner's IP is neither (punching a hole for
# it would be worse than the problem). So instead of a network ping it watches the
# RUNNER REGISTRATION state via the GitHub API — wait for the krg-deploy runner to
# drop offline (the switch stopped it) and return online on the new code. This is
# the barrier that keeps the post-substrate job from resuming on a control node that
# is mid-switch.
#
# Requires GH_TOKEN with Administration:read on the repo (the self-hosted-runners
# API needs it; the default GITHUB_TOKEN cannot be granted that scope). Wire it from
# an Actions secret — see deploy/README.md.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN (a token with Administration:read on this repo) is required to read runner status}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
# Which self-hosted runner to watch. Do NOT read this from $RUNNER_NAME: this script
# runs on a GitHub-HOSTED runner, where the Actions runtime auto-injects RUNNER_NAME
# as the HOSTED runner's own name (e.g. "GitHub Actions 1000009607"). That non-empty
# value defeats a `${RUNNER_NAME:-krg-deploy}` default, so the watcher would poll for
# a runner that isn't in the repo's self-hosted list and time out. Use a private,
# non-reserved variable name instead.
TARGET_RUNNER="${TARGET_RUNNER:-krg-deploy}"
OFFLINE_TIMEOUT="${OFFLINE_TIMEOUT:-300}" # 5 min to observe it go down
ONLINE_TIMEOUT="${ONLINE_TIMEOUT:-900}"   # 15 min to observe it come back
POLL="${POLL_INTERVAL:-10}"

# .status is "online" | "offline". --paginate in case there are >30 runners.
status_of() {
  NAME="$TARGET_RUNNER" gh api "repos/${REPO}/actions/runners" --paginate \
    --jq '.runners[] | select(.name==env.NAME) | .status' 2>/dev/null | head -n1
}

wait_for() { # <desired-status> <timeout> <label>
  local want="$1" timeout="$2" label="$3" waited=0 st
  echo "waiting for runner '${TARGET_RUNNER}' to be ${want} (${label}; timeout ${timeout}s)…"
  while ((waited < timeout)); do
    st="$(status_of || true)"
    echo "  [+${waited}s] status=${st:-<unknown>}"
    [[ "$st" == "$want" ]] && {
      echo "  → ${want}"
      return 0
    }
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  echo "TIMEOUT after ${timeout}s waiting for status=${want}."
  return 1
}

# 1) The switch takes the runner offline (krg-deploy-selfswitch.sh stops it for the
#    whole switch, so this transition is always observable).
if ! wait_for offline "$OFFLINE_TIMEOUT" "switch started"; then
  echo "FATAL: runner never went offline — the scheduled self-update may not have fired."
  echo "       Check deploy/deploy-self-update.sh output and 'systemctl status krg-deploy-selfupdate.timer' on the box."
  exit 1
fi
# 2) It re-registers once the switch completes and the runner restarts on new code.
if ! wait_for online "$ONLINE_TIMEOUT" "switch completed"; then
  echo "FATAL: runner did not come back online — the control node may be wedged mid-switch."
  echo "       Recover out-of-band (Proxmox console; journalctl -u krg-deploy-selfupdate.service)."
  exit 1
fi
echo "OK: krg-deploy is back online — the deploy can resume."
