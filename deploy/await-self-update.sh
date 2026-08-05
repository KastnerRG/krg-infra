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
# API needs it; the default GITHUB_TOKEN cannot be granted that scope). deploy.yml
# mints it as a 1h installation token from the "krg-infra deploy watcher" GitHub App
# — see deploy/README.md.
#
# FAILS FAST ON A BAD CREDENTIAL. `gh api` prints the error BODY to stdout on a
# non-2xx, so a naive `status=$(gh api … | head -1)` reads back a literal "{" and is
# indistinguishable from "the runner is still online" — run 30758029212 burned the
# full 300s timeout that way and then blamed the switch unit, which had in fact
# worked. So: check gh's exit status, preflight the API once before the wait loops,
# and treat a persistently unreadable API as fatal rather than as a poll tick.
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
# How many CONSECUTIVE unreadable polls to tolerate before giving up. A blip against
# api.github.com shouldn't abort a deploy, but a dead credential should surface in
# ~30s instead of consuming the whole timeout.
MAX_API_ERRORS="${MAX_API_ERRORS:-3}"

# status_of() reports through these globals rather than stdout, because a caller
# would have to wrap it in "$(…)" to read stdout — and a command substitution is a
# SUBSHELL, so any variable it set (like the error text) would be discarded exactly
# when it is needed. Globals + a plain call keep the failure detail reachable.
STATUS=''    # last successfully read status: "online" | "offline" | "" if unregistered
API_ERROR='' # stderr of the last failed read, for the operator-facing message
# Private scratch file for gh's stderr. mktemp, not a fixed /tmp path: this script is
# also run by hand on krg-deploy (deploy/README.md), where a predictable name is a
# symlink-clobber surface.
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

# Read the runner's status into $STATUS. Returns non-zero — leaving $STATUS
# untouched — if the API call itself failed, so a 401/403/rate-limit body can never
# be mistaken for a status. --paginate in case there are >30 runners.
status_of() {
  local out rc=0
  # `gh api` writes the error BODY to stdout and the diagnostic to stderr; keep them
  # apart so only a genuine 2xx response can reach $STATUS.
  out="$(NAME="$TARGET_RUNNER" gh api "repos/${REPO}/actions/runners" --paginate \
    --jq '.runners[] | select(.name==env.NAME) | .status' 2>"$ERR_FILE")" || rc=$?
  API_ERROR="$(tr -d '\r' <"$ERR_FILE" | head -n3)"
  ((rc == 0)) || return "$rc"
  STATUS="$(printf '%s\n' "$out" | head -n1)"
}

# Confirm the credential works and the runner exists BEFORE committing to a timeout.
# Both failures here are configuration errors that no amount of waiting will fix.
preflight() {
  if ! status_of; then
    echo "FATAL: cannot read the self-hosted-runners API for ${REPO}."
    # A plain `if`, not `[[ … ]] && echo`: under `set -e` a false test in an && list
    # is only survivable because it isn't the final command — too subtle to rely on.
    if [[ -n "$API_ERROR" ]]; then echo "       ${API_ERROR}"; fi
    echo "       The watcher authenticates as the 'krg-infra deploy watcher' GitHub App"
    echo "       (DEPLOY_WATCHER_APP_ID + DEPLOY_WATCHER_APP_PRIVATE_KEY Actions secrets)."
    echo "       Check the App still has Administration:read and is installed on this repo."
    echo "       NOTE: krg-deploy's own switch is unaffected by this — deploy-post's"
    echo "       deploy-self-verify.sh is what actually proves the new generation took."
    exit 1
  fi
  if [[ -z "$STATUS" ]]; then
    echo "FATAL: no self-hosted runner named '${TARGET_RUNNER}' is registered on ${REPO}."
    echo "       The runner is NOT ephemeral (nix/hosts/krg-deploy/default.nix), so it"
    echo "       should stay registered across the switch — an absent one means the"
    echo "       registration was lost, not that it is mid-restart."
    exit 1
  fi
  echo "preflight: API readable; runner '${TARGET_RUNNER}' is currently ${STATUS}."
}

wait_for() { # <desired-status> <timeout> <label>
  local want="$1" timeout="$2" label="$3" waited=0 errors=0
  echo "waiting for runner '${TARGET_RUNNER}' to be ${want} (${label}; timeout ${timeout}s)…"
  while ((waited < timeout)); do
    if status_of; then
      errors=0
      echo "  [+${waited}s] status=${STATUS:-<not registered>}"
      [[ "$STATUS" == "$want" ]] && {
        echo "  → ${want}"
        return 0
      }
    else
      errors=$((errors + 1))
      echo "  [+${waited}s] API read failed (${errors}/${MAX_API_ERRORS}): ${API_ERROR}"
      if ((errors >= MAX_API_ERRORS)); then
        echo "FATAL: ${errors} consecutive API failures — the watcher's token is not usable."
        echo "       Not waiting out the remaining $((timeout - waited))s on a credential that cannot work."
        return 1
      fi
    fi
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  echo "TIMEOUT after ${timeout}s waiting for status=${want}."
  return 1
}

# 0) Prove the credential and the runner registration are both usable up front.
preflight

# 1) The switch takes the runner offline (krg-deploy-selfswitch.sh stops it for the
#    whole switch, so this transition is always observable).
if ! wait_for offline "$OFFLINE_TIMEOUT" "switch started"; then
  echo "FATAL: runner never went offline — the scheduled self-update may not have fired."
  echo "       Check deploy/deploy-self-update.sh output and, on the box,"
  echo "       'systemctl status krg-deploy-selfupdate.service' (a SERVICE, triggered by"
  echo "       the deploy — there is no selfupdate timer)."
  exit 1
fi
# 2) It re-registers once the switch completes and the runner restarts on new code.
if ! wait_for online "$ONLINE_TIMEOUT" "switch completed"; then
  echo "FATAL: runner did not come back online — the control node may be wedged mid-switch."
  echo "       Recover out-of-band (Proxmox console; journalctl -u krg-deploy-selfupdate.service)."
  exit 1
fi
echo "OK: krg-deploy is back online — the deploy can resume."
