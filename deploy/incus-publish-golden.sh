#!/usr/bin/env bash
# Build the KRG Incus GOLDEN TEMPLATE (ADR 0017 §7, gate 3) and publish it to krg-nat's
# image store under the alias `krg-golden` — the image every tenant instance boots from
# (terraform/incus var.tenants.<t>.image = "krg-golden").
#
# WHAT IT DOES
#   1. `nix build` the image artifacts from nixosConfigurations.krg-golden:
#        .config.system.build.qemuImage  — the qcow2-compressed VM disk
#        .config.system.build.metadata   — the Incus image-metadata tarball
#      (both from nix/golden/default.nix's incus-virtual-machine.nix import). On the
#      krg-deploy self-hosted runner the store is warm, so an unchanged image is a
#      no-op rebuild (cache hit) — cheap to run every deploy.
#   2. Import them into krg-nat and (re)point the `krg-golden` alias at the result —
#      IDEMPOTENTLY: the source nix store path is stamped as an image property, and if
#      the currently-published `krg-golden` already came from this exact store path the
#      import is skipped entirely.
#
# AUTH — same mTLS-over-fleet-PKI model as deploy-tofu.sh's incus target (NOT a
# hand-configured `incus remote` on the runner — that would be drift). We log in to
# OpenBao with krg-deploy's AppRole (the one on-disk secret the deploy legs already
# use), mint a short-lived client cert from pki_int/issue/incus-client into a throwaway
# INCUS_CONF dir, and add a scratch `krg-nat` remote there. krg-nat PKI-trusts any
# fleet-signed cert (core.trust_ca_certificates + server.ca, nix/modules/incus.nix), so
# no `incus config trust add`. The dir is removed on exit.
#
# WHERE IT RUNS: the krg-deploy control node (has Nix + reaches krg-nat's ucsd-restricted
# API), wired into the CD between Phase 2 (systems) and Phase 3 (config), so the alias
# exists before terraform/incus could launch an instance from it.
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE="${REPO_ROOT}/nix"

ALIAS="${GOLDEN_ALIAS:-krg-golden}"
REMOTE="krg-nat"
INCUS_API="${INCUS_API_ADDRESS:-https://krg-nat.ucsd.edu:8443}"

# OpenBao AppRole identity — the SAME files deploy-tofu.sh / the Ansible leg read.
export VAULT_ADDR="${VAULT_ADDR:-https://krg-vault.ucsd.edu:8200}"
role_id_file="${OPENBAO_ROLE_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-role-id}"
secret_id_file="${OPENBAO_SECRET_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-secret-id}"

# ── 1. Build the image artifacts ─────────────────────────────────────────────────
# Resolve the two out paths in one evaluation. --no-link: we reference the store paths
# directly (this box's store is the artifact source stamped for idempotency).
echo "==> building the golden-template image (nixosConfigurations.krg-golden)"
read -r qcow_out meta_out < <(
  nix build --no-link --print-out-paths \
    "${FLAKE}#nixosConfigurations.krg-golden.config.system.build.qemuImage" \
    "${FLAKE}#nixosConfigurations.krg-golden.config.system.build.metadata" \
    | paste -sd' ' -
)
[[ -n "${qcow_out:-}" && -n "${meta_out:-}" ]] || { echo "ERROR: image build produced no out paths" >&2; exit 1; }

# The disk (qcow2-compressed) and the metadata tarball live inside those out paths under
# names nixpkgs picks (nixos.qcow2 / *.tar.xz) — discover rather than hard-code.
qcow="$(find "$qcow_out" -maxdepth 2 -type f \( -name '*.qcow2' -o -name '*.img' -o -name '*.raw' \) | head -n1)"
meta="$(find "$meta_out" -maxdepth 2 -type f \( -name '*.tar.xz' -o -name '*.tar.gz' -o -name '*.tar' \) | head -n1)"
[[ -f "$qcow" ]] || { echo "ERROR: no disk image under $qcow_out" >&2; exit 1; }
[[ -f "$meta" ]] || { echo "ERROR: no metadata tarball under $meta_out" >&2; exit 1; }
# The qcow store path is the publish identity: it changes iff the image content changes.
SRC="$qcow_out"
echo "    disk:     $qcow"
echo "    metadata: $meta"
echo "    source:   $SRC"

# ── 2. Mint a short-lived incus client cert (mirror deploy-tofu.sh's incus target) ──
[[ -r "$role_id_file" && -r "$secret_id_file" ]] \
  || { echo "ERROR: OpenBao AppRole not provisioned ($role_id_file / $secret_id_file)" >&2; exit 1; }
VAULT_TOKEN="$(bao write -field=token auth/approle/login \
  role_id="$(< "$role_id_file")" secret_id="$(< "$secret_id_file")")" \
  || { echo "ERROR: OpenBao AppRole login failed" >&2; exit 1; }
export VAULT_TOKEN

icj="$(bao write -format=json pki_int/issue/incus-client common_name=krg-deploy ttl=1h)" \
  || { echo "ERROR: could not issue incus-client cert (is the openbao target applied?)" >&2; exit 1; }

INCUS_CONF="$(mktemp -d)"
export INCUS_CONF
trap 'rm -rf "${INCUS_CONF:-}"' EXIT
# client.crt = leaf + issuing CA so krg-nat can chain the leaf to its server.ca.
{ jq -r '.data.certificate' <<<"$icj"; jq -r '.data.issuing_ca' <<<"$icj"; } >"${INCUS_CONF}/client.crt"
jq -r '.data.private_key' <<<"$icj" >"${INCUS_CONF}/client.key"
chmod 600 "${INCUS_CONF}/client.key"

# Scratch remote in this throwaway config dir. --accept-certificate stores krg-nat's
# (self-signed) server cert; the client cert above is the PKI-trusted identity, so no
# token/password is needed.
incus remote add "$REMOTE" "$INCUS_API" --accept-certificate --auth-type tls >/dev/null

# ── 3. Idempotent import + alias ──────────────────────────────────────────────────
cur_src="$(incus image get-property "${REMOTE}:${ALIAS}" krg.source 2>/dev/null || true)"
if [[ -n "$cur_src" && "$cur_src" == "$SRC" ]]; then
  echo "==> ${ALIAS} already published from ${SRC} — up to date, nothing to do"
  exit 0
fi

# Fingerprint the currently-aliased image (if any) so we can GC it after re-pointing.
old_fp="$(incus image alias list "${REMOTE}:" --format csv 2>/dev/null | awk -F, -v a="$ALIAS" '$1==a{print $2}')"

echo "==> importing new golden image to ${REMOTE}"
imp="$(incus image import "$meta" "$qcow" "${REMOTE}:" --property krg.source="$SRC")"
new_fp="$(sed -n 's/.*fingerprint:[[:space:]]*//p' <<<"$imp" | head -n1)"
[[ -n "$new_fp" ]] || { echo "ERROR: could not parse the imported image fingerprint from: $imp" >&2; exit 1; }

# (Re)point the alias atomically-ish: drop any existing one, create it on the new fp.
incus image alias delete "${REMOTE}:${ALIAS}" 2>/dev/null || true
incus image alias create "${REMOTE}:${ALIAS}" "$new_fp"
echo "==> ${ALIAS} -> ${new_fp}"

# GC the previous image so the store doesn't accumulate old templates.
if [[ -n "$old_fp" && "$old_fp" != "$new_fp" ]]; then
  incus image delete "${REMOTE}:${old_fp}" 2>/dev/null \
    && echo "    removed previous image ${old_fp}" \
    || echo "    note: could not remove previous image ${old_fp} (in use?) — left in place"
fi

echo "==> golden template published"
