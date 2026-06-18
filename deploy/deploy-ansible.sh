#!/usr/bin/env bash
# Apply the Ansible layer from the control node (krg-deploy).
#
# By default this mirrors the nightly `ansible-apply` timer in
# nix/hosts/krg-deploy/default.nix: it runs ONLY playbooks/site.yml (the
# Proxmox/Debian hypervisor hosts). site.yml connects to fabricant as root over
# SSH (push mode — see ansible/inventory/hosts.yml).
#
# The Synology NAS apply is gated by DEPLOY_SYNOLOGY=true. By default it runs the
# FULL playbook (the entire NAS): its declarative sync converges e4e-nas to spec,
# DELETING live config not in spec — drift reduction, the same model as
# impermanence on the NixOS hosts. SYNOLOGY_TAGS narrows it (e.g.
# `synology_garage` for just the garage slice); empty = full.
#
# All NAS secrets are materialized from OpenBao below (#110): garage + users
# (break-glass e4e-admin + e4e-automation API account; humans come from AD via
# winbind, not created here) + snmp are REQUIRED; garage-ui-oidc + dsm-sso-oidc +
# hyper-backup + ad-join are optional. A missing REQUIRED secret fails the synology
# apply — it never falls through to an empty password.
#
# OPERATOR PRECONDITION for the FULL run: the spec must already capture intended
# live state (bring-up — pre-flight captures + .dss backup + `--check --diff`
# first, docs/e4e-nas-dsm.md), else the sync deletes intended-but-unspecced
# config. Keep DEPLOY_SYNOLOGY off until that reconciliation is done.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Host-key checking is intentionally NOT overridden here — ansible/ansible.cfg sets
# host_key_checking = True, and we keep that (krg-deploy's known_hosts must include
# the fleet host keys, provisioned out-of-band). Don't weaken it to unblock a run.
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/var/lib/krg-admin/.ssh/id_ed25519}"
[[ -f "$DEPLOY_SSH_KEY" ]] && export ANSIBLE_PRIVATE_KEY_FILE="${ANSIBLE_PRIVATE_KEY_FILE:-$DEPLOY_SSH_KEY}"

# ── OEC (campus-mandated Qualys + Trellix) ──────────────────────────────────
# Same credentialed archive + policy as the NixOS layer (deploy-nixos.sh): the
# agents are mandatory on every host, so a missing archive is fatal — never a
# silently-unhardened hypervisor. We pass the control-node path to site.yml as
# `oec_installer`; the oec_qualys_trellix role copies it to the host, runs the
# vendor installer, and verifies both daemons are active (the deploy fails if
# they aren't). The role still no-ops gracefully when oec_installer is unset, so
# `--check`/local runs are unaffected — enforcement lives here in the CD path.
OEC_INSTALLER="${OEC_INSTALLER:-/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz}"
if [[ ! -r "$OEC_INSTALLER" ]]; then
  echo "FATAL: OEC installer not readable on the control node: $OEC_INSTALLER"
  echo "       Stage it out-of-band (see deploy/README.md) — hypervisors cannot be hardened without it."
  exit 1
fi

echo "::group::ansible site.yml (Proxmox hosts)"
# if ! (...) so set -e can't exit before ::endgroup:: — keeps the Actions log group
# closed on failure (same pattern as deploy-nixos.sh / deploy-tofu.sh).
if ! (
  cd "${REPO_ROOT}/ansible"
  # Collections (ansible/requirements.yml) are provisioned ON the control node, not
  # installed per-run — this matches the nightly ansible-apply service and avoids an
  # unpinned upstream pull on every deploy (non-reproducible). Pinning them and
  # managing the install via Nix so both paths share one set is tracked in #129.
  # ad_require_joined=true: gate the deploy on a working AD join (the ad_client role
  # asserts `adcli testjoin --domain` per host). Strict on the automated path; manual
  # first-bring-up runs omit it so an unjoined host stages config + warns instead.
  ansible-playbook playbooks/site.yml -e "oec_installer=${OEC_INSTALLER}" -e ad_require_joined=true
); then
  echo "FAILED: ansible site.yml"
  printf '\n::endgroup::\n'
  exit 1
fi
printf '\n::endgroup::\n'

SYNOLOGY_TAGS="${SYNOLOGY_TAGS:-}"   # empty = full playbook (entire NAS); set e.g. synology_garage to narrow
role_id_file="${OPENBAO_ROLE_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-role-id}"
secret_id_file="${OPENBAO_SECRET_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-secret-id}"

if [[ "${DEPLOY_SYNOLOGY:-false}" != "true" ]]; then
  echo "skip synology: DEPLOY_SYNOLOGY!=true"
elif [[ ! -r "$role_id_file" || ! -r "$secret_id_file" ]]; then
  # Graceful skip (not fatal) so a not-yet-provisioned control node doesn't fail
  # the whole fleet deploy — proxmox/nix already applied above. Provision the
  # AppRole then the next run picks it up. See docs/krg-deploy-ansible-setup.md.
  echo "skip synology: OpenBao AppRole creds not provisioned ($role_id_file / $secret_id_file) — see docs/krg-deploy-ansible-setup.md"
else
  echo "::group::ansible synology (e4e-nas) — tags=${SYNOLOGY_TAGS:-<full>}"
  if ! (
    cd "${REPO_ROOT}/ansible/synology"

    # --- Materialize NAS secrets from OpenBao --------------------------------
    # OpenBao (krg-vault) is the source of truth; krg-deploy reads the e4e-nas
    # secrets at apply time via its AppRole and writes them to a short-lived
    # JSON extra-vars file. The synology roles consume them as the SAME
    # extra_vars an operator would pass with `-e @…` — no role change, no
    # in-playbook vault lookup (the synology subtree stays zero-prereq). Reads
    # require the secret/data/e4e-nas/* capability on the krg-deploy AppRole
    # (terraform/openbao/main.tf). Secrets never hit argv or the log; the file
    # is mode-0600 (umask) and shredded on exit.
    export VAULT_ADDR="${VAULT_ADDR:-https://krg-vault.ucsd.edu:8200}"

    # AppRole login → short-lived token (kept in env, never on argv).
    VAULT_TOKEN="$(bao write -field=token auth/approle/login \
      role_id="$(< "$role_id_file")" secret_id="$(< "$secret_id_file")")" \
      || { echo "FATAL: OpenBao AppRole login failed"; exit 1; }
    export VAULT_TOKEN

    umask 077
    vars_file="$(mktemp -t synology-vars.XXXXXX.json)"
    trap 'shred -u "$vars_file" 2>/dev/null || rm -f "$vars_file"' EXIT

    # jq escapes every value (no quote/YAML injection). REQUIRED groups
    # (garage / users / snmp) abort the run if unreadable — never fall through to
    # an empty password. OPTIONAL groups (garage-ui-oidc / dsm-sso-oidc /
    # hyper-backup / ad-join) are omitted when absent: garage-ui-oidc + dsm-sso-oidc
    # only exist after terraform/authentik runs (and are needed only when spec has a
    # `ui:` / `oidc:` block respectively); hyper-backup jobs are empty today;
    # ad_join_password is a one-time join input. Layout: #110 /
    # docs/krg-deploy-ansible-setup.md "Seeding".
    # echo the error to STDERR (a `$(...)`-captured stdout would hide it) and
    # return non-zero so the `|| exit 1` aborts the synology apply (→ FAILED).
    _req() { bao kv get -format=json "$1" 2>/dev/null || { echo "FATAL: cannot read $1 (seed it — docs/krg-deploy-ansible-setup.md)" >&2; return 1; }; }
    garage="$(_req secret/e4e-nas/garage)" || exit 1
    users="$(_req secret/e4e-nas/users)"   || exit 1   # {e4e-admin: <pw>, e4e-automation: <pw>}
    snmp="$(_req secret/e4e-nas/snmp)"     || exit 1   # {auth_password, priv_password}
    oidc_secret=""; oidc_secret="$(bao kv get -field=client_secret secret/e4e-nas/garage-ui-oidc 2>/dev/null || true)"
    dsm_sso="";     dsm_sso="$(bao kv get -field=client_secret secret/e4e-nas/dsm-sso-oidc    2>/dev/null || true)"
    ad_join="";     ad_join="$(bao kv get -field=join_password   secret/e4e-nas/ad             2>/dev/null || true)"
    hb='{}'; if _hb="$(bao kv get -format=json secret/e4e-nas/hyper-backup 2>/dev/null)"; then hb="$(jq '.data.data' <<<"$_hb")"; fi

    jq -n \
      --argjson g "$(jq '.data.data' <<<"$garage")" \
      --argjson u "$(jq '.data.data' <<<"$users")" \
      --argjson s "$(jq '.data.data' <<<"$snmp")" \
      --argjson hb "$hb" \
      --arg oidc "$oidc_secret" \
      --arg dsmsso "$dsm_sso" \
      --arg adjoin "$ad_join" \
      '{
        garage_rpc_secret:       $g.rpc_secret,
        garage_admin_token:      $g.admin_token,
        garage_metrics_token:    $g.metrics_token,
        synology_user_passwords: $u,
        nas_admin_password:      $u["e4e-admin"],
        snmp_v3_auth_password:   $s.auth_password,
        snmp_v3_priv_password:   $s.priv_password,
        hyper_backup_secrets:    $hb
      }
      + (if $oidc   != "" then { garage_ui_oidc_client_secret: $oidc }   else {} end)
      + (if $dsmsso != "" then { dsm_sso_oidc_client_secret: $dsmsso }   else {} end)
      + (if $adjoin != "" then { ad_join_password: $adjoin }            else {} end)' \
      > "$vars_file"

    ansible-playbook playbook.yml ${SYNOLOGY_TAGS:+--tags "$SYNOLOGY_TAGS"} -e @"$vars_file"
  ); then
    echo "FAILED: ansible synology"
    printf '\n::endgroup::\n'
    exit 1
  fi
  printf '\n::endgroup::\n'
fi

# ── KRG.LOCAL Active Directory structure (ansible/krg-ad/, ADR 0010) ─────────
# Converges groups / service accounts / ACL delegations / password policy on
# krg-ldap by wrapping samba-tool. Gated OFF by default (DEPLOY_KRG_AD=true) like
# the synology apply — keep it off until spec/krg-ad/ reflects the intended live
# state. NO secrets: the apply is structural only (it never creates a service
# account or sets a password — those stay in OpenBao), so there's no AppRole
# materialization here. Reaches krg-ldap over SSH as krg-admin (become root); the
# apply is NON-AUTHORITATIVE (adds, never deletes) so it can't clobber roster-set
# human group membership.
if [[ "${DEPLOY_KRG_AD:-false}" != "true" ]]; then
  echo "skip krg-ad: DEPLOY_KRG_AD!=true"
else
  echo "::group::ansible krg-ad (KRG.LOCAL Active Directory)"
  if ! (
    cd "${REPO_ROOT}/ansible/krg-ad"
    ansible-playbook playbook.yml
  ); then
    echo "FAILED: ansible krg-ad"
    printf '\n::endgroup::\n'
    exit 1
  fi
  printf '\n::endgroup::\n'
fi
