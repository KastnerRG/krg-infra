#!/usr/bin/env bash
# Apply the OpenTofu layer from the control node (krg-deploy) — one root module
# per target, applied in dependency order.
#
# SECRETS COME FROM OPENBAO, not from files on disk. krg-deploy authenticates to
# OpenBao (krg-vault) with its AppRole — the SAME role_id/secret_id the Ansible
# leg already uses (deploy/deploy-ansible.sh) — and reads each target's creds from
# KV at apply time. There is no per-target `.deploy-env`: a stray secrets folder on
# the control node is just drift waiting to happen (and duplicates what OpenBao
# exists to hold). The only thing on disk is the AppRole identity itself (already
# required by the Ansible leg). See the per-target materialization below for the
# exact KV paths; seed them with `bao kv put` (#112).
#
# WHICH TARGETS run is an explicit, in-git opt-in via TOFU_TARGETS (set in
# .github/workflows/deploy.yml, like SYNOLOGY_TAGS scopes the Ansible synology
# converge) — NOT implied by whether a secret happens to be seeded. Default is
# empty, so this is inert until a target is deliberately listed. A listed target
# whose KV secret isn't seeded yet skips with a notice (seed it, next run applies).
#
# OPENBAO is special: it PROVISIONS OpenBao's own mount/auth/policies, so it can't
# authenticate with the AppRole it's creating (and widening the AppRole to manage
# its own auth backend would be a privilege-escalation smell). It needs a
# privileged operator token, supplied out-of-band via TOFU_OPENBAO_TOKEN — normally
# a manual `TOFU_TARGETS=openbao TOFU_OPENBAO_TOKEN=<root> ./deploy/deploy-tofu.sh`
# at bootstrap / when its structure changes, not part of the routine push-CD.
#
# STATE is local on krg-deploy (ADR 0005) and MUST persist across runs — the CI
# checkout is ephemeral, so state lives under TOFU_STATE_ROOT, not in the workdir
# (a fresh checkout would otherwise have empty state and try to recreate/destroy
# everything). State is ALWAYS encrypted via TOFU_STATE_PASSPHRASE — ADR 0005
# mandates state encryption, and the state holds live secrets (VAULT_TOKEN, the
# DSM password, OIDC client secrets). A target that is about to apply but has NO
# passphrase is a HARD failure, not a silent plaintext write (see the guard below).
set -euo pipefail

# OpenTofu state + provider cache (and any tooling temp files) hold secrets — make
# everything this script creates owner-only by default.
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
STATE_ROOT="${TOFU_STATE_ROOT:-/var/lib/krg-admin/tofu-state}"

# OpenBao AppRole identity — same files the Ansible leg reads (the ONE on-disk
# secret, already provisioned for that leg; terraform/openbao/main.tf mints them).
export VAULT_ADDR="${VAULT_ADDR:-https://krg-vault.ucsd.edu:8200}"
role_id_file="${OPENBAO_ROLE_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-role-id}"
secret_id_file="${OPENBAO_SECRET_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-secret-id}"

# WHICH targets to apply — explicit opt-in (default: none). openbao first when
# listed (it provisions the AppRoles the others authenticate with), then configs.
read -r -a TARGETS <<< "${TOFU_TARGETS:-}"
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "no TOFU_TARGETS set — nothing to apply (set e.g. TOFU_TARGETS=\"authentik grafana e4e-nas\")"
  exit 0
fi

# AppRole login → short-lived token for the consuming targets (authentik / grafana
# / e4e-nas). Kept in env, never on argv. If the AppRole isn't provisioned yet,
# proceed without it — only openbao (which uses its own TOFU_OPENBAO_TOKEN) can run
# then; the consuming targets skip when their KV reads fail below.
if [[ -r "$role_id_file" && -r "$secret_id_file" ]]; then
  VAULT_TOKEN="$(bao write -field=token auth/approle/login \
    role_id="$(< "$role_id_file")" secret_id="$(< "$secret_id_file")")" \
    || { echo "FATAL: OpenBao AppRole login failed"; exit 1; }
  export VAULT_TOKEN
else
  echo "note: OpenBao AppRole not provisioned ($role_id_file / $secret_id_file) —"
  echo "      only openbao (via TOFU_OPENBAO_TOKEN) can apply; consuming targets will skip."
fi

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

# Read one KV field; non-zero (and a STDERR notice) if the path/field is unreadable
# — the caller turns that into a per-target skip (seed it, next run applies).
_kv() { # <path> <field>
  bao kv get -field="$2" "$1" 2>/dev/null \
    || { echo "  seed ${1} (field ${2}) in OpenBao — skipping this target" >&2; return 1; }
}

# Populate the env a target's tofu config expects, all from OpenBao. Returns
# non-zero to SIGNAL A SKIP (missing secret / missing bootstrap token) — distinct
# from an apply error, which fails the whole deploy. Runs inside the per-target
# subshell, so VAULT_TOKEN overrides and TF_VAR_* exports don't leak across targets.
materialize() { # <target>
  case "$1" in
    grafana)
      # providers.tf + sso.tf read grafana-admin + grafana-oidc from OpenBao via
      # the vault provider (VAULT_ADDR/VAULT_TOKEN already exported) — nothing else.
      [[ -n "${VAULT_TOKEN:-}" ]] || { echo "  no VAULT_TOKEN (AppRole) — skipping grafana" >&2; return 1; }
      ;;
    authentik)
      [[ -n "${VAULT_TOKEN:-}" ]] || { echo "  no VAULT_TOKEN (AppRole) — skipping authentik" >&2; return 1; }
      TF_VAR_authentik_token="$(_kv secret/krg-deploy/authentik-admin-token token)" || return 1
      TF_VAR_ldap_bind_password="$(_kv secret/krg-deploy/authentik-bind password)" || return 1
      export TF_VAR_authentik_token TF_VAR_ldap_bind_password
      ;;
    e4e-nas)
      [[ -n "${VAULT_TOKEN:-}" ]] || { echo "  no VAULT_TOKEN (AppRole) — skipping e4e-nas" >&2; return 1; }
      # DSM API account password lives with the other NAS user passwords the
      # Ansible leg already reads (secret/e4e-nas/users → {<user>: <pw>}), so the
      # tofu + ansible legs share one source. dsm_user is non-secret (default below).
      export TF_VAR_dsm_user="${TF_VAR_dsm_user:-e4e-automation}"
      TF_VAR_dsm_password="$(_kv secret/e4e-nas/users "$TF_VAR_dsm_user")" || return 1
      export TF_VAR_dsm_password
      # TOTP secret only if 2FA is on the API account (optional). Use an `if`, not
      # `[[ … ]] && …`: as the LAST statement in this branch a false test would make
      # materialize() return non-zero → the loop silently SKIPS e4e-nas even though
      # the password resolved fine. (Bit us: accounts without 2FA → empty otp.)
      local otp; otp="$(bao kv get -field=secret secret/e4e-nas/dsm-otp 2>/dev/null || true)"
      if [[ -n "$otp" ]]; then export TF_VAR_dsm_otp_secret="$otp"; fi
      ;;
    openbao)
      # Can't bootstrap OpenBao from OpenBao — needs a privileged operator token.
      if [[ -z "${TOFU_OPENBAO_TOKEN:-}" ]]; then
        echo "  openbao needs a privileged token (TOFU_OPENBAO_TOKEN) — skipping" >&2
        return 1
      fi
      export VAULT_TOKEN="$TOFU_OPENBAO_TOKEN"   # override the AppRole token, this subshell only
      ;;
    *)
      echo "  no materialization rule for ${1} — skipping" >&2
      return 1
      ;;
  esac
}

# Fail-fast: stop on the first target that ERRORS during apply (a skip — missing
# dir, unseeded secret, no bootstrap token — is intentional and does not stop the
# run). Targets apply in dependency order (openbao first), so continuing past a
# failed dependency would only produce confusing follow-on failures.
for t in "${TARGETS[@]}"; do
  dir="${TF_DIR}/${t}"
  if [[ ! -d "$dir" ]]; then
    echo "skip ${t}: no terraform/${t}/ target"
    continue
  fi

  state_dir="${STATE_ROOT}/${t}"

  echo "::group::tofu apply ${t}"
  rc=0
  (
    # Materialize creds from OpenBao; a non-zero return here is a SKIP (exit 0),
    # not a deploy failure. Everything after this point is a real apply.
    if ! materialize "$t"; then
      echo "skip ${t}: creds not available (see notice above)"
      exit 0
    fi

    # Fail-closed on encryption: we are about to write state that holds secrets.
    # ADR 0005 mandates encrypted state — refuse to write it in the clear.
    if [[ -z "${TOFU_STATE_PASSPHRASE:-}" ]]; then
      echo "ERROR: ${t} is ready to apply but TOFU_STATE_PASSPHRASE is unset —" >&2
      echo "       refusing to write UNENCRYPTED state (ADR 0005). Set the" >&2
      echo "       TOFU_STATE_PASSPHRASE Actions secret (or export it locally)." >&2
      exit 3   # distinct from a skip(0) / apply-fail(1) — a hard config error
    fi

    mkdir -p "$state_dir"
    chmod 700 "$state_dir"   # owner-only even if it pre-existed with looser perms
    export TF_DATA_DIR="${state_dir}/.terraform"   # provider cache off the ephemeral checkout
    tofu -chdir="$dir" init -input=false
    tofu -chdir="$dir" apply -auto-approve -input=false \
         -state="${state_dir}/terraform.tfstate"
  ) || rc=$?
  echo "::endgroup::"
  if [[ $rc -ne 0 ]]; then
    echo "FAILED: ${t} (exit ${rc}) — stopping; remaining targets not applied"
    exit 1
  fi
done
