#!/usr/bin/env bash
# Phase 1.5 bootstrap only: the final value belongs exclusively to the Authentik
# workspace. CAS=0 never overwrites an issued token (including on concurrent runs).
# Called with the deployer's existing OpenBao session after the secrets apply.
set -euo pipefail
path=secret/krg-prod/authentik-managed/roster-invitations
if bao kv get "$path" >/dev/null 2>&1; then
  exit 0
fi
if bao kv put -cas=0 "$path" placeholder=1 >/dev/null 2>&1; then
  echo "Prepared roster invitation secret path; Authentik will populate it in phase 3."
elif ! bao kv get "$path" >/dev/null 2>&1; then
  echo "ERROR: cannot prepare/read roster invitation secret path; refusing phase-2 activation." >&2
  exit 1
fi
