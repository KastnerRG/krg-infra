#!/usr/bin/env bash
# Mint a GitHub Actions runner REGISTRATION token for a repo, from the org's GitHub
# App identity in OpenBao (ADR 0022 §2). Prints ONLY the short-lived registration
# token to stdout — the caller renders/pushes it to a runner's tokenFile.
#
# Usage: mint-runner-token.sh <owner>/<repo>
#   e.g. mint-runner-token.sh UCSD-E4E/fishsense-lite
#
# Reads secret/krg-deploy/github-app/<owner> = { app_id, installation_id, private_key }
# (seed it per docs/tenant-runner-bringup.md §4). Flow: App JWT (RS256, <=10 min) →
# installation access token (1h) → runner registration token (~1h). The App private
# key never leaves this process (read from OpenBao into a temp file, used to sign,
# shredded on exit); nothing but the registration token is emitted.
#
# OpenBao auth: uses $VAULT_TOKEN if set, else krg-deploy's AppRole creds (the same
# files the other deploy legs use). Run on krg-deploy.
set -euo pipefail
umask 077

repo="${1:?usage: mint-runner-token.sh <owner>/<repo>}"
owner="${repo%%/*}"

export VAULT_ADDR="${VAULT_ADDR:-https://krg-vault.ucsd.edu:8200}"
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  rid_f="${OPENBAO_ROLE_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-role-id}"
  sid_f="${OPENBAO_SECRET_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-secret-id}"
  [[ -r "$rid_f" && -r "$sid_f" ]] || { echo "ERROR: no VAULT_TOKEN and no AppRole creds ($rid_f / $sid_f)" >&2; exit 1; }
  VAULT_TOKEN="$(bao write -field=token auth/approle/login role_id="$(<"$rid_f")" secret_id="$(<"$sid_f")")" \
    || { echo "ERROR: OpenBao AppRole login failed" >&2; exit 1; }
  export VAULT_TOKEN
fi

# App identity (KV-v2). private_key goes to a temp file (openssl needs a file); never printed.
j="$(bao kv get -format=json "secret/krg-deploy/github-app/${owner}")" \
  || { echo "ERROR: cannot read secret/krg-deploy/github-app/${owner} — seed it (docs/tenant-runner-bringup.md §4)" >&2; exit 1; }
app_id="$(jq -r '.data.data.app_id' <<<"$j")"
install_id="$(jq -r '.data.data.installation_id' <<<"$j")"
[[ -n "$app_id" && "$app_id" != "null" && -n "$install_id" && "$install_id" != "null" ]] \
  || { echo "ERROR: app_id/installation_id missing in secret/krg-deploy/github-app/${owner}" >&2; exit 1; }
keyfile="$(mktemp)"
trap 'shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"' EXIT
jq -r '.data.data.private_key' <<<"$j" >"$keyfile"

# App JWT (RS256), exp <= 10 min, iat backdated 60s for clock skew.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now="$(date +%s)"
hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
pld="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | b64url)"
sig="$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -sign "$keyfile" -binary | b64url)"
jwt="${hdr}.${pld}.${sig}"

gh_api() { curl -fsS -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

# Installation access token (1h) → runner registration token (~1h).
itok="$(gh_api -H "Authorization: Bearer ${jwt}" -X POST \
  "https://api.github.com/app/installations/${install_id}/access_tokens" | jq -r '.token')" \
  || { echo "ERROR: could not mint installation token (check app_id/installation_id/key + App install)" >&2; exit 1; }
[[ -n "$itok" && "$itok" != "null" ]] || { echo "ERROR: empty installation token" >&2; exit 1; }

reg="$(gh_api -H "Authorization: token ${itok}" -X POST \
  "https://api.github.com/repos/${repo}/actions/runners/registration-token")" \
  || { echo "ERROR: could not mint registration token for ${repo} (is the App installed on it, with Administration:write?)" >&2; exit 1; }
echo "minted runner registration token for ${repo}, expires_at=$(jq -r '.expires_at' <<<"$reg")" >&2
jq -er '.token' <<<"$reg"
