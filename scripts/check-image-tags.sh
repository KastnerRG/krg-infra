#!/usr/bin/env bash
# Verify every compose `image:` tag ACTUALLY EXISTS on its registry.
#
# Why this isn't a `nix flake check`: nix build/check run in a hermetic sandbox
# with NO network, so a derivation can't ask a registry whether a tag exists. A
# nonexistent tag is just an opaque string — it passes every CI gate and only
# fails at deploy-time `docker compose up -d` with "manifest unknown". That bit
# us: #465 pinned `temporalio/auto-setup:1.31.2` (a Temporal *server* version;
# the auto-setup IMAGE has no such tag) → the stack crash-looped and exhausted
# Docker Hub's pull limit, red-lining krg-prod for hours (fixed #472). This
# preflight catches that class at PR time.
#
# Uses `skopeo inspect`, which speaks each registry's anonymous-token flow
# (docker.io / ghcr.io / quay.io / a custom host) uniformly. Run it with skopeo
# on PATH — scripts/lint.sh wraps it in `nix shell nixpkgs#skopeo`.
#
# Failure policy — deliberately narrow so CI is neither flaky nor dependent on
# private creds: HARD-fail ONLY on a genuinely-missing tag (manifest unknown /
# not found). Registries that need auth even to inspect (e.g. nvcr.io with an
# API key) and transient network errors are SKIPPED with a warning.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)" || exit 1

command -v skopeo >/dev/null 2>&1 || {
  echo "FATAL: skopeo not on PATH — run via: nix shell nixpkgs#skopeo --command $0" >&2
  exit 2
}

# Collect image refs from every compose file. Matches both `image: <ref>` and the
# `x-*-image: &anchor <ref>` anchor definitions; skips `image: *anchor` references
# (the leading `*` is excluded) since the anchor's definition is already covered.
mapfile -t refs < <(
  grep -rhoE '^[[:space:]]*(image:|x-[a-z-]+image:[[:space:]]*&[a-z-]+)[[:space:]]*[^*[:space:]#]+' \
    "$root/nix/docker-compose" --include='*.yml' 2>/dev/null |
    sed -E 's/#.*//' |
    grep -oE '[a-zA-Z0-9][a-zA-Z0-9._/-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*$' |
    sort -u
)

[ "${#refs[@]}" -gt 0 ] || {
  echo "FATAL: found no image: refs under nix/docker-compose — extraction broke?" >&2
  exit 2
}

fail=0
missing=()
for ref in "${refs[@]}"; do
  if out="$(skopeo inspect --no-tags --raw "docker://${ref}" 2>&1)"; then
    printf 'ok:      %s\n' "$ref"
  elif grep -qiE 'manifest unknown|not (found|known)|manifest for .* not found|no such|does not exist|reference does not exist' <<<"$out"; then
    printf 'MISSING: %s\n' "$ref"
    missing+=("$ref")
    fail=1
  elif grep -qiE 'unauthor|authentication (required|needed)|denied|forbidden|x-api-key|invalid username|requires authentication' <<<"$out"; then
    printf 'skip:    %s  (registry needs auth to inspect)\n' "$ref"
  else
    printf 'warn:    %s  (transient? not failing) -- %s\n' "$ref" "$(tr '\n' ' ' <<<"$out" | cut -c1-160)"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "FAIL: ${#missing[@]} image tag(s) do NOT exist on their registry:"
  printf '  - %s\n' "${missing[@]}"
  echo "Fix the tag in the compose file (verify with: skopeo inspect docker://<ref>)."
  exit 1
fi
echo
echo "ok: all ${#refs[@]} image tags exist"
