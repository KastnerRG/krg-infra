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
# everything). State is ALWAYS encrypted via TOFU_STATE_PASSPHRASE — ADR 0005
# mandates state encryption, and the state holds live secrets (VAULT_TOKEN, the
# DSM password, OIDC client secrets). A target that is about to apply (its
# .deploy-env exists) but has NO passphrase is a HARD failure, not a silent
# plaintext write — see the per-target guard below. Skip-targets never reach it,
# so this script is still safe to land before any creds OR the passphrase exist.
set -euo pipefail

# OpenTofu state + provider cache (and any tooling temp files) hold secrets — make
# everything this script creates owner-only by default.
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
STATE_ROOT="${TOFU_STATE_ROOT:-/var/lib/krg-admin/tofu-state}"

# Apply order: openbao first (it provisions the AppRoles the others authenticate
# with), then the config targets. Override with TOFU_TARGETS="a b c".
read -r -a TARGETS <<< "${TOFU_TARGETS:-openbao authentik grafana e4e-nas}"

# State encryption (the `encryption` block can't read variables — supply via env).
# HCL-escape the passphrase before interpolating so a `\` or `"` can't corrupt the
# encryption config; a newline can't be represented in this inline HCL string, so
# reject it rather than emit invalid HCL.
if [[ -n "${TOFU_STATE_PASSPHRASE:-}" ]]; then
  if [[ "$TOFU_STATE_PASSPHRASE" == *$'\n'* ]]; then
    echo "ERROR: TOFU_STATE_PASSPHRASE must not contain a newline" >&2
    exit 2
  fi
  esc=${TOFU_STATE_PASSPHRASE//\\/\\\\}   # \ -> \\
  esc=${esc//\"/\\\"}                     # " -> \"
  export TF_ENCRYPTION='
  key_provider "pbkdf2" "k" { passphrase = "'"$esc"'" }
  method "aes_gcm" "m"      { keys = key_provider.pbkdf2.k }
  state { method = method.aes_gcm.m }
  plan  { method = method.aes_gcm.m }'
fi

# Fail-fast: stop on the first target that errors. Targets apply in dependency
# order (openbao first — it provisions the AppRoles the others authenticate with),
# so continuing past a failed dependency would only produce partial/confusing
# follow-on failures. (A missing dir or .deploy-env is an intentional skip, not a
# failure, and does not stop the run.)
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

  # Fail-closed on encryption: we are about to apply a REAL target, so its state
  # WILL hold secrets. ADR 0005 mandates encrypted state — refuse to write it in
  # the clear. (The top-level block above only exports TF_ENCRYPTION when the
  # passphrase is set; this turns "silently unencrypted" into a hard stop, but
  # only once a credentialed target actually runs — skips above never get here.)
  if [[ -z "${TOFU_STATE_PASSPHRASE:-}" ]]; then
    echo "ERROR: ${t} has creds (${envf}) but TOFU_STATE_PASSPHRASE is unset" >&2
    echo "       — refusing to write UNENCRYPTED state (ADR 0005). Set the" >&2
    echo "       TOFU_STATE_PASSPHRASE Actions secret (or export it for a local" >&2
    echo "       run) before applying this target." >&2
    exit 2
  fi

  state_dir="${STATE_ROOT}/${t}"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"   # enforce owner-only even if it pre-existed with looser perms

  echo "::group::tofu apply ${t}"
  if ! (
    set -a            # export everything the env file sets
    # shellcheck disable=SC1090
    source "$envf"
    set +a
    # Persist provider cache + state OUTSIDE the ephemeral checkout.
    export TF_DATA_DIR="${state_dir}/.terraform"
    tofu -chdir="$dir" init -input=false
    tofu -chdir="$dir" apply -auto-approve -input=false \
         -state="${state_dir}/terraform.tfstate"
  ); then
    echo "FAILED: ${t} — stopping; remaining targets not applied"
    echo "::endgroup::"
    exit 1
  fi
  echo "::endgroup::"
done
