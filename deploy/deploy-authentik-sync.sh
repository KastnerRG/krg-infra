#!/usr/bin/env bash
# Drive an Authentik LDAP-source sync from AD, synchronously, as a deploy step —
# run AFTER the Ansible krg-ad phase (which creates AD groups) and BEFORE the
# OpenTofu authentik phase (which looks them up).
#
# WHY THIS EXISTS (deploy ordering, ADR 0011). terraform/authentik gates apps by
# LOOKING UP AD groups in Authentik (data.authentik_group, e.g. app_access.tf).
# Those groups reach Authentik ONLY through the LDAP source sync (ldap.tf,
# `sync_groups = true`), which normally runs on Authentik's own timer (hours). So a
# single deploy that (a) creates a NEW AD group in the Ansible krg-ad phase and
# (b) references it in the OpenTofu authentik phase races that timer: tofu runs
# minutes later, the group hasn't synced, and the lookup fails hard with
#   Error: No matching groups found  (data.authentik_group.access["<group>"])
# — which is exactly what took the fleet deploy red when the "Label Studio Users"
# gate landed (its AD group and the tile binding merged in one PR).
#
# This step closes that window: once the group exists in AD, drive a FULL sync NOW
# so it's present when tofu reads it. `ak ldap_sync <slug>` runs the sync in the
# FOREGROUND and exits when it finishes — synchronous, so there's no poll loop and
# no residual race with the phase that follows. (Authentik exposes no REST endpoint
# to trigger a sync — only GET .../sync/status/ — so the management command in the
# worker container is the supported trigger.)
#
# NOT a live one-shot mutation (IaC-strict is fine): a sync only PULLS declared AD
# state into Authentik's cache — the same reconciliation the timer does — it does
# not author config. It's orchestration, like `tofu apply`.
#
# BEST-EFFORT by design: a sync failure here only WARNs. The authoritative gate is
# the tofu authentik apply that follows — if a referenced group is genuinely still
# missing it fails there, loudly, on the exact lookup. And on a from-scratch deploy
# where the Authentik stack isn't up yet, this must not block the rest of the fleet.
# Idempotent: in steady state it re-syncs unchanged data and exits 0.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

# The Authentik stack + its LDAP source both live on krg-prod. The worker
# container name is pinned in nix/docker-compose/krg-prod/compose.authentik.yml
# (container_name: authentik_worker); the source slug in terraform/authentik/ldap.tf
# (authentik_source_ldap.samba_ad.slug = "krg-samba-ad"). Override for a differently
# named stack/source without editing this script.
host="${DEPLOY_AUTHENTIK_HOST:-krg-prod}"
container="${DEPLOY_AUTHENTIK_WORKER:-authentik_worker}"
slug="${DEPLOY_AUTHENTIK_LDAP_SLUG:-krg-samba-ad}"
target="$(target_for "$host")"

echo "::group::Authentik LDAP sync (${slug}) on ${host} (${target})"
# krg-admin is not in the docker group; it has passwordless sudo (see lib.sh) — go
# through sudo so the exec works without widening the break-glass account.
# container/slug are in-script constants; expanding them client-side is intended (SC2029).
# shellcheck disable=SC2029
if ssh "${sshopts[@]}" "$target" "sudo docker exec ${container} ak ldap_sync ${slug}"; then
  echo "OK: Authentik LDAP sync completed — new AD groups are now visible to tofu."
else
  rc=$?
  echo "WARN: Authentik LDAP sync did not complete cleanly on ${host} (exit ${rc})." >&2
  echo "      Continuing — the tofu authentik apply that follows will fail loudly if" >&2
  echo "      a referenced AD group is still missing. If it does, check the source:" >&2
  echo "        ssh ${target} sudo docker exec ${container} ak ldap_sync ${slug}" >&2
fi
printf '\n::endgroup::\n'

# Never fail the deploy from here — the tofu authentik apply is the real gate.
exit 0
