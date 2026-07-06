#!/usr/bin/env bash
# Stage each Incus TENANT instance's OpenBao secret-zero (ADR 0021 §3).
#
# A tenant instance runs krg.vaultAgent (nixosModules.tenant) to mint its OWN
# <tenant>.vm server cert, which needs the tenant AppRole's role-id + secret-id on
# box. Unlike a fleet host (deploy-nixos.sh stages secret-zero over ssh), a tenant
# instance is on the Incus internal NAT (no ssh) and is converged by the TENANT's
# runner, not krg-deploy — and the tenant must NOT mint its own secret-id (that would
# be self-granting a credential the admin owns, ADR 0020 §3). So krg-deploy pushes it
# here, at provision, via `incus file push` through krg-nat: the SAME
# mint-fresh-per-deploy model as the fleet path, only the transport differs (ssh →
# incus file push).
#
# Runs every deploy (CD Phase 3.6, AFTER Phase 3 creates the instances): a fresh
# secret-id per run keeps it well inside expiry, and it is idempotent. BEST-EFFORT:
# a tenant whose AppRole isn't applied yet, or an instance still booting / stopped,
# is skipped with a warning rather than failing the deploy — matching the
# golden-publish leg. The in-instance agent fails CLOSED without its secret-zero, so
# a miss degrades that one tenant (no stack), never the fleet.
#
# AUTH: identical mTLS-over-fleet-PKI to incus-publish-golden.sh — AppRole login,
# mint a short-lived incus-client cert into a throwaway INCUS_CONF, add a scratch
# krg-nat remote. No hand-configured remote, no secret at rest on the runner (creds
# are pushed over stdin, never written to disk).
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FLAKE="${REPO_ROOT}/nix"
REMOTE="krg-nat"
INCUS_API="${INCUS_API_ADDRESS:-https://krg-nat.ucsd.edu:8443}"

# Where the in-instance vault-agent reads its AppRole creds — MUST match krg.vaultAgent's
# roleIdFile / secretIdFile defaults (nix/modules/services/vault-agent.nix).
AGENT_DIR="/var/lib/krg/openbao-agent"
# Where the in-instance github-runner reads its registration token — MUST match the
# tokenFile dir in nixosModules.tenant (nix/modules/tenant.nix, ADR 0022).
RUNNER_DIR="/var/lib/krg/github-runner"

export VAULT_ADDR="${VAULT_ADDR:-https://krg-vault.ucsd.edu:8200}"
role_id_file="${OPENBAO_ROLE_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-role-id}"
secret_id_file="${OPENBAO_SECRET_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-secret-id}"

# incus CLI — resolve from the flake (krg-nat's OWN package, so client/server versions
# match) if not on PATH; the runner service may not see the NixOS system profile. Mirrors
# incus-publish-golden.sh.
INCUS_BIN="$(command -v incus || true)"
if [[ -z "$INCUS_BIN" ]]; then
  echo "==> incus not on PATH — resolving from the flake (krg-nat's incus package)"
  INCUS_BIN="$(nix build --no-link --print-out-paths \
    "${FLAKE}#nixosConfigurations.krg-nat.config.virtualisation.incus.package")/bin/incus"
fi
incus() { "$INCUS_BIN" "$@"; }

# ── AppRole login + short-lived incus-client cert → throwaway remote ──────────────
[[ -r "$role_id_file" && -r "$secret_id_file" ]] \
  || { echo "ERROR: OpenBao AppRole not provisioned ($role_id_file / $secret_id_file)" >&2; exit 1; }
VAULT_TOKEN="$(bao write -field=token auth/approle/login \
  role_id="$(<"$role_id_file")" secret_id="$(<"$secret_id_file")")" \
  || { echo "ERROR: OpenBao AppRole login failed" >&2; exit 1; }
export VAULT_TOKEN

icj="$(bao write -format=json pki_int/issue/incus-client common_name=krg-deploy ttl=1h)" \
  || { echo "ERROR: could not issue incus-client cert (is the openbao target applied?)" >&2; exit 1; }

INCUS_CONF="$(mktemp -d)"
export INCUS_CONF
trap 'rm -rf "${INCUS_CONF:-}"' EXIT
{ jq -r '.data.certificate' <<<"$icj"; jq -r '.data.issuing_ca' <<<"$icj"; } >"${INCUS_CONF}/client.crt"
jq -r '.data.private_key' <<<"$icj" >"${INCUS_CONF}/client.key"
chmod 600 "${INCUS_CONF}/client.key"
incus remote add "$REMOTE" "$INCUS_API" --accept-certificate --auth-type tls >/dev/null

# ── enumerate tenant instances + push each one's secret-zero ──────────────────────
# Every Incus instance is a tenant (krg-nat runs tenant VMs only); its name == its
# project == the tenant slug == the AppRole suffix (terraform/incus + terraform/openbao
# both key on the slug). JSON+jq (not `-c`) so the project field is unambiguous.
mapfile -t rows < <(incus list "${REMOTE}:" --all-projects --format json 2>/dev/null \
  | jq -r '.[] | "\(.name)\t\(.project)"' || true)
if [[ ${#rows[@]} -eq 0 ]]; then
  echo "==> no Incus tenant instances — nothing to stage"
  exit 0
fi

# Push both creds over stdin (`-`), retrying to ride out a VM still booting (file push
# needs the guest incus-agent up). --create-dirs makes AGENT_DIR on a fresh golden
# instance (before its tenant flake converges + tmpfiles owns the dir); role-id is
# non-secret (0644), secret-id is 0600, both root-owned.
push_one() { # <name> <project> <rid> <sid>
  local name="$1" project="$2" rid="$3" sid="$4"
  for _ in 1 2 3 4 5 6; do
    if printf '%s' "$rid" | incus file push --project "$project" - \
      "${REMOTE}:${name}${AGENT_DIR}/role-id" --create-dirs --uid 0 --gid 0 --mode 0644 2>/dev/null \
      && printf '%s' "$sid" | incus file push --project "$project" - \
        "${REMOTE}:${name}${AGENT_DIR}/secret-id" --uid 0 --gid 0 --mode 0600 2>/dev/null; then
      return 0
    fi
    sleep 10 # VM agent not up yet — wait and retry (≈50s total)
  done
  return 1
}

rc=0
for row in "${rows[@]}"; do
  name="${row%%$'\t'*}"
  project="${row##*$'\t'}"
  [[ -n "$name" ]] || continue
  role="tenant-${name}"

  rid="$(bao read -field=role_id "auth/approle/role/${role}/role-id" 2>/dev/null)" || {
    echo "::warning::skip ${name}: AppRole '${role}' not found (apply terraform/openbao)"
    continue
  }
  sid="$(bao write -f -field=secret_id "auth/approle/role/${role}/secret-id" 2>/dev/null)" || {
    echo "::warning::skip ${name}: could not mint secret-id for '${role}'"
    rc=1
    continue
  }

  if push_one "$name" "$project" "$rid" "$sid"; then
    echo "  staged secret-zero for ${name} (AppRole ${role})"
  else
    echo "::warning::${name}: incus file push failed after retries (instance stopped/booting?)"
    rc=1
  fi

  # Runner registration token (ADR 0022 §3): if the instance is tagged with its GitHub
  # repo (terraform/incus stamps user.krg_repo), broker a fresh token from the org's
  # GitHub App and push it where nixosModules.tenant's runner reads it. Best-effort like
  # secret-zero: a missing App/seed or a booting VM warns, never fails the fleet.
  repo="$(incus config get "$name" --project "$project" user.krg_repo 2>/dev/null || true)"
  if [[ -n "$repo" ]]; then
    if regtok="$("${SCRIPT_DIR}/mint-runner-token.sh" "$repo" 2>/dev/null)" && [[ -n "$regtok" ]]; then
      if printf '%s' "$regtok" | incus file push --project "$project" - \
        "${REMOTE}:${name}${RUNNER_DIR}/registration-token" --create-dirs --uid 0 --gid 0 --mode 0600 2>/dev/null; then
        echo "  staged runner token for ${name} (repo ${repo})"
      else
        echo "::warning::${name}: runner token push failed (instance stopped/booting?)"
        rc=1
      fi
    else
      echo "::warning::skip runner token for ${name}: could not mint for ${repo} (App installed on the repo + seeded to OpenBao?)"
    fi
  fi
done

exit "$rc"
