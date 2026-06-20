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
  # One-time migration of a PRE-EXISTING UNENCRYPTED state: set TOFU_STATE_MIGRATE=1
  # to add an `unencrypted` fallback method so tofu can READ the plaintext state and
  # REWRITE it encrypted (aes_gcm) on apply. Run once per plaintext-state target,
  # then drop the flag (leaving the fallback on permanently would defeat encryption).
  # HCL: a block with an argument on the `{` line must close `}` on that same line.
  # So the no-fallback form stays single-line; the migrate form uses a multi-line
  # block (method + fallback on their own lines).
  if [[ -n "${TOFU_STATE_MIGRATE:-}" ]]; then
    migrate_method='
  method "unencrypted" "migrate" {}'
    state_blocks='state {
    method = method.aes_gcm.m
    fallback { method = method.unencrypted.migrate }
  }
  plan {
    method = method.aes_gcm.m
    fallback { method = method.unencrypted.migrate }
  }'
  else
    migrate_method=''
    state_blocks='state { method = method.aes_gcm.m }
  plan  { method = method.aes_gcm.m }'
  fi
  export TF_ENCRYPTION='
  key_provider "pbkdf2" "k" { passphrase = "'"$esc"'" }
  method "aes_gcm" "m"      { keys = key_provider.pbkdf2.k }'"$migrate_method"'
  '"$state_blocks"
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
      # Pre-flight both KV reads here so an unseeded secret SKIPS with a notice
      # rather than hard-failing the apply when the vault data source resolves
      # (matches the authentik/e4e-nas pattern). grafana-oidc is produced by the
      # authentik target's write-back; grafana-admin is seeded manually.
      [[ -n "${VAULT_TOKEN:-}" ]] || { echo "  no VAULT_TOKEN (AppRole) — skipping grafana" >&2; return 1; }
      _kv secret/krg-prod/grafana-admin password >/dev/null || return 1
      _kv secret/krg-prod/authentik-managed/grafana-oidc client_id >/dev/null || return 1
      ;;
    authentik)
      [[ -n "${VAULT_TOKEN:-}" ]] || { echo "  no VAULT_TOKEN (AppRole) — skipping authentik" >&2; return 1; }
      TF_VAR_authentik_token="$(_kv secret/krg-deploy/authentik-admin-token token)" || return 1
      # LDAP bind password lives under krg-prod (it's an authentik-service secret,
      # consumed by the LDAP outpost on krg-prod too) — krg-deploy's policy grants a
      # scoped read on this exact path (../terraform/openbao/main.tf).
      TF_VAR_ldap_bind_password="$(_kv secret/krg-prod/authentik-ldap bind_password)" || return 1
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
    temporal)
      # The temporal provider builds its mTLS client at CONFIGURE time, so cert/key/ca
      # must be KNOWN AT PLAN — they can't come from an in-tofu vault resource (provider
      # configures before the resource exists → "failed to find any PEM data"). So mint
      # a short-lived client cert HERE (ONE issuance → matching cert+key) and pass it as
      # vars. krg-deploy's AppRole holds pki_int/issue/temporal-client; lives only in env.
      [[ -n "${VAULT_TOKEN:-}" ]] || { echo "  no VAULT_TOKEN (AppRole) — skipping temporal" >&2; return 1; }
      local cj
      cj="$(bao write -format=json pki_int/issue/temporal-client common_name=krg-deploy ttl=1h 2>/dev/null)" \
        || { echo "  could not issue temporal-client cert — skipping temporal" >&2; return 1; }
      TF_VAR_temporal_client_cert="$(jq -r '.data.certificate' <<<"$cj")"
      TF_VAR_temporal_client_key="$(jq -r '.data.private_key' <<<"$cj")"
      TF_VAR_temporal_ca_cert="$(jq -r '.data.issuing_ca' <<<"$cj")"
      export TF_VAR_temporal_client_cert TF_VAR_temporal_client_key TF_VAR_temporal_ca_cert
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
    # TOFU_IMPORT: one-time, value-preserving state adoptions before plan/apply. Each
    # line is "ADDR KVPATH FIELD" — the script reads FIELD from KVPATH in OpenBao
    # (VAULT_TOKEN already set) and `tofu import`s it into ADDR, adopting an existing
    # live value WITHOUT rotating it (e.g. a DB password when generation moves to
    # terraform/secrets). Reading from OpenBao keeps the secret out of the caller's
    # shell/env. Idempotent: an ADDR already in state is skipped. Runs against the
    # real -state + TF_ENCRYPTION, so no hand-rolled encryption dance.
    if [[ -n "${TOFU_IMPORT:-}" ]]; then
      while read -r imp_addr imp_path imp_field; do
        [[ -z "$imp_addr" ]] && continue
        if tofu -chdir="$dir" state list -state="${state_dir}/terraform.tfstate" 2>/dev/null \
             | grep -qxF "$imp_addr"; then
          echo "  import: ${imp_addr} already in state — skipping"
          continue
        fi
        imp_val="$(_kv "$imp_path" "$imp_field")" \
          || { echo "  import: cannot read ${imp_path} (${imp_field}) — skipping ${imp_addr}" >&2; continue; }
        tofu -chdir="$dir" import -input=false -state="${state_dir}/terraform.tfstate" \
             "$imp_addr" "$imp_val"
      done <<< "$TOFU_IMPORT"
    fi
    # TOFU_PLAN_ONLY: dry-run a target against its REAL (encrypted, persistent) state
    # without applying — for validating a change before it lands. It still reads the
    # encrypted state (so the passphrase guard above applies) but never writes it.
    # Do NOT run a bare `tofu plan` by hand in the target dir: that uses empty local
    # state and reports "create everything", which is meaningless (and dangerous to
    # apply). Always go through this so the real -state + TF_ENCRYPTION are wired.
    if [[ -n "${TOFU_PLAN_ONLY:-}" ]]; then
      tofu -chdir="$dir" plan -input=false \
           -state="${state_dir}/terraform.tfstate"
    else
      tofu -chdir="$dir" apply -auto-approve -input=false \
           -state="${state_dir}/terraform.tfstate"
    fi
  ) || rc=$?
  printf '\n::endgroup::\n'
  if [[ $rc -ne 0 ]]; then
    echo "FAILED: ${t} (exit ${rc}) — stopping; remaining targets not applied"
    exit 1
  fi
done
