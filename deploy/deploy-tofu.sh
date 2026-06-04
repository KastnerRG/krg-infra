#!/usr/bin/env bash
# Apply the OpenTofu layer from the control node (krg-deploy) — one root module
# per target, applied in dependency order.
#
# SECRETS stay OUT of git. A target applies ONLY if terraform/<target>/.deploy-env
# exists (gitignored, operator/OpenBao-provided); it is sourced to export whatever
# that target needs (VAULT_TOKEN, TF_VAR_*, …). Targets without it are skipped with
# a notice — so this script is safe to land before any creds are wired, and it does
# not hardcode the openbao/authentik secret plumbing owned by the parallel effort.
#
# STATE is local on krg-deploy (ADR 0005) and MUST persist across runs — the CI
# checkout is ephemeral, so state lives under TOFU_STATE_ROOT, not in the workdir
# (a fresh checkout would otherwise have empty state and try to recreate/destroy
# everything). State is encrypted when TOFU_STATE_PASSPHRASE is set (terraform/README).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
STATE_ROOT="${TOFU_STATE_ROOT:-/var/lib/krg-admin/tofu-state}"

# Apply order: openbao first (it provisions the AppRoles the others authenticate
# with), then the config targets. Override with TOFU_TARGETS="a b c".
read -r -a TARGETS <<< "${TOFU_TARGETS:-openbao authentik grafana e4e-nas}"

# State encryption (the `encryption` block can't read variables — supply via env).
if [[ -n "${TOFU_STATE_PASSPHRASE:-}" ]]; then
  export TF_ENCRYPTION='
  key_provider "pbkdf2" "k" { passphrase = "'"$TOFU_STATE_PASSPHRASE"'" }
  method "aes_gcm" "m"      { keys = key_provider.pbkdf2.k }
  state { method = method.aes_gcm.m }
  plan  { method = method.aes_gcm.m }'
fi

rc=0
for t in "${TARGETS[@]}"; do
  dir="${TF_DIR}/${t}"
  envf="${dir}/.deploy-env"
  if [[ ! -d "$dir" ]]; then
    echo "skip ${t}: no terraform/${t}/ target"
    continue
  fi
  if [[ ! -f "$envf" ]]; then
    echo "skip ${t}: no ${envf} (creds not wired) — not applying"
    continue
  fi

  state_dir="${STATE_ROOT}/${t}"
  mkdir -p "$state_dir"

  echo "::group::tofu apply ${t}"
  (
    set -a            # export everything the env file sets
    # shellcheck disable=SC1090
    source "$envf"
    set +a
    # Persist provider cache + state OUTSIDE the ephemeral checkout.
    export TF_DATA_DIR="${state_dir}/.terraform"
    tofu -chdir="$dir" init -input=false
    tofu -chdir="$dir" apply -auto-approve -input=false \
         -state="${state_dir}/terraform.tfstate"
  ) || { echo "FAILED: ${t}"; rc=1; }
  echo "::endgroup::"
done

exit "$rc"
