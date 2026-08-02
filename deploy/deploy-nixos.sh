#!/usr/bin/env bash
# Rebuild NixOS hosts in the flake from the control node (krg-deploy).
#
# Activation is non-interactive because the break-glass admin (krg-admin, or
# e4e-admin on E4E hosts — see USER_OVERRIDE in deploy/lib.sh) has sudoNoPassword
# on every host (nix/users/admin.nix), so `nixos-rebuild --sudo` needs no password
# prompt. The control node's deploy key is authorized for BOTH admin accounts
# (nix/keys/admins.json). Each host BUILDS ITS OWN config (--build-host =
# --target-host) so krg-deploy (a small VM) never has to build waiter's
# NVIDIA/CUDA closure or copy gigabytes around — it only evaluates + orchestrates.
#
# PHASED DEPLOY (ADR 0011): this script REBUILDS only — it does NOT verify. The
# phased pipeline (.github/workflows/deploy.yml) calls it TWICE:
#   • phase 0 (foundation) — DEPLOY_NIXOS_HOSTS="krg-vault krg-ldap", BEFORE Ansible.
#     krg-ldap carries the in-guest AD firewall the Ansible substrate phase depends
#     on (it must open the DC ports to fabricant before fabricant can validate AD),
#     and krg-vault brings up OpenBao. Hoisting them removes the NixOS→Ansible
#     back-edge that no single layer ordering could satisfy.
#   • phase 2 (systems) — DEPLOY_NIXOS_HOSTS="krg-prod waiter kastner-ml", AFTER it.
#     The compute boxes mount /home from the NFS exports the Ansible phase creates.
# OEC + AD membership are checked in the FINAL verify phase (deploy/deploy-verify.sh),
# never here — so a health gate can't deadlock the converge meant to satisfy it.
#
# krg-deploy ITSELF is intentionally excluded (not in ORDER): it runs this deploy,
# and a self-switch can restart the github-runner service mid-job — so it must never
# be switched INLINE here. On the push path it self-updates via the multistage flow
# (deploy/deploy-self-update.sh schedules a DETACHED switch; deploy/await-self-update.sh
# gates the resume) and, as a fallback, the nightly system.autoUpgrade in
# nix/profiles/base.nix.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Shared host map + SSH setup (ORDER, ADDR, USER_OVERRIDE, target_for, sshopts,
# FLAKE, ADMIN, NIX_SSHOPTS) — also used by deploy-verify.sh; kept in one place.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

# Which hosts to rebuild this invocation. DEPLOY_NIXOS_HOSTS = space-separated
# subset of ORDER (must be known hosts); unset = the full ORDER (a manual, single-
# shot full rebuild). Hosts always rebuild in ORDER (dependency-first) regardless
# of the order they're listed in the env.
declare -A WANT=()
if [[ -n "${DEPLOY_NIXOS_HOSTS:-}" ]]; then
  read -r -a _sel <<< "$DEPLOY_NIXOS_HOSTS"
  for h in "${_sel[@]}"; do
    if [[ -z "${ADDR[$h]:-}" ]]; then
      echo "FATAL: DEPLOY_NIXOS_HOSTS names unknown host '$h' (known: ${!ADDR[*]})"
      exit 2
    fi
    WANT[$h]=1
  done
else
  for h in "${ORDER[@]}"; do WANT[$h]=1; done
fi

# ── OEC (campus-mandated Qualys Cloud Agent + Trellix HX/xagt) ───────────────
# These agents are mandatory on EVERY host. The credentialed installer archive
# (live ActivationId/CustomerId — gitignored, .secrets/ is too) is staged
# out-of-band on the control node; we scp it to each host's runtime path BEFORE
# the rebuild so that switch's oec-install oneshot enrolls on the SAME run
# (modules/security/oec-qualys-trellix.nix gates the oneshot on this path). A
# missing archive is fatal — we never deploy a silently-unhardened host. (Whether
# both daemons actually came up is asserted later, in deploy/deploy-verify.sh.)
OEC_INSTALLER="${OEC_INSTALLER:-/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz}"
OEC_DEST="/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz"
if [[ ! -r "$OEC_INSTALLER" ]]; then
  echo "FATAL: OEC installer not readable on the control node: $OEC_INSTALLER"
  echo "       Stage it out-of-band (see deploy/README.md) — hosts cannot be hardened without it."
  exit 1
fi
# Sanity-check the archive HERE (it's a tar — plain or compressed; tar -tf
# auto-detects) so a corrupt/truncated/wrong-format file fails fast on the
# control node with a clear message, rather than surfacing as an opaque
# oec-install failure mid-rebuild on the first host (which is how the gzip-vs-
# plain-tar mismatch first bit us).
if ! tar -tf "$OEC_INSTALLER" >/dev/null 2>&1; then
  echo "FATAL: OEC installer is not a readable tar archive: $OEC_INSTALLER"
  echo "       Re-stage the vendor archive (it is a tar — plain or gz; corrupt/truncated otherwise)."
  exit 1
fi

# Push the OEC archive to <target> and install it root-owned 0600 at OEC_DEST.
# scp lands it as krg-admin in /tmp, then sudo-installs into the root-owned
# /var/lib/krg/oec (krg-admin can't write there directly); sudoNoPassword
# (nix/users/admin.nix) keeps it non-interactive. Re-pushing identical bytes
# each deploy is harmless — the oneshot's own sentinel makes enrollment one-time.
stage_oec() {
  local target="$1"
  # &&-chained (not two statements): called as `if ! stage_oec`, which suspends
  # set -e inside the function, so a failed scp must short-circuit explicitly.
  # OEC_DEST is a fixed in-script constant, so expanding it client-side (rather
  # than on the remote) is intended — silence SC2029 for this command.
  # shellcheck disable=SC2029
  scp "${sshopts[@]}" "$OEC_INSTALLER" "${target}:/tmp/oec-installer.tgz" \
    && ssh "${sshopts[@]}" "$target" "
        set -e
        sudo install -d -m 0700 -o root -g root /var/lib/krg/oec
        sudo install -m 0600 -o root -g root /tmp/oec-installer.tgz '${OEC_DEST}'
        rm -f /tmp/oec-installer.tgz
      "
}

# ── OpenBao vault-agent secret-zero (krg.vaultAgent hosts) ───────────────────
# A host running krg.vaultAgent (waiter/kastner-ml XRDP cert from pki_int; krg-prod
# Guacamole/Temporal secrets) needs its AppRole role-id + secret-id ON BOX BEFORE
# the switch, or openbao-agent can't authenticate and its dependent units (xrdp, the
# compose stacks) fail to start. krg-deploy mints + stages them here — same
# before-the-switch pattern as the OEC archive — using the SAME AppRole the
# tofu/ansible legs use (granted role-id read + secret-id create in
# terraform/openbao). NOTHING is hand-placed or committed: the role-id is read and a
# secret-id freshly minted per deploy, pushed over ssh STDIN so the secret never
# lands on argv/ps/logs. This replaces the manual "mint a secret-id and scp it"
# bootstrap (ADR 0009 per-host secret-zero) for every vault-agent host.
export VAULT_ADDR="${VAULT_ADDR:-https://krg-vault.ucsd.edu:8200}"
_va_role_id_file="${OPENBAO_ROLE_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-role-id}"
_va_secret_id_file="${OPENBAO_SECRET_ID_FILE:-/var/lib/krg-admin/.secrets/openbao-secret-id}"
# Log in with krg-deploy's own AppRole (its secret-zero IS hand-placed — the one
# bootstrap that can't be automated away). Empty token => staging fails closed for
# any vault-agent host below (and is a no-op for hosts that don't use the agent).
VAULT_TOKEN=""
if [[ -r "$_va_role_id_file" && -r "$_va_secret_id_file" ]]; then
  VAULT_TOKEN="$(bao write -field=token auth/approle/login \
    role_id="$(< "$_va_role_id_file")" secret_id="$(< "$_va_secret_id_file")" 2>/dev/null || true)"
fi
export VAULT_TOKEN

# Write <stdin> to a root-owned file at <target>:<path> with <mode> — content via ssh
# STDIN only (never argv). Pre-creates the dir + the file (sets mode/owner), then tee
# writes the bytes (tee keeps the existing file's mode/owner).
push_root_file() { # <target> <path> <mode>   (content on stdin)
  local target="$1" path="$2" mode="$3" dir
  dir="$(dirname "$path")"
  # shellcheck disable=SC2029  # paths are local constants; expand client-side intentionally
  ssh "${sshopts[@]}" "$target" "
      set -e
      sudo install -d -m 0700 -o root -g root '${dir}'
      sudo install -m '${mode}' -o root -g root /dev/null '${path}'
      sudo tee '${path}' >/dev/null
    "
}

# Stage <host>'s vault-agent secret-zero if it uses krg.vaultAgent (else no-op).
# Fatal for that host if staging fails — don't switch a box whose agent will fail to
# authenticate (mirrors the OEC precondition).
stage_vault_secret_zero() {
  local host="$1" target="$2" enabled rolename ridfile sidfile rid sid
  enabled="$(nix eval "${FLAKE}#nixosConfigurations.${host}.config.krg.vaultAgent.enable" 2>/dev/null || echo false)"
  [[ "$enabled" == "true" ]] || return 0
  if [[ -z "$VAULT_TOKEN" ]]; then
    echo "  FAILED: ${host} uses krg.vaultAgent but the control node has no OpenBao AppRole creds (${_va_role_id_file} / ${_va_secret_id_file})"
    return 1
  fi
  rolename="$(nix eval --raw "${FLAKE}#nixosConfigurations.${host}.config.krg.vaultAgent.roleName" 2>/dev/null)" || return 1
  ridfile="$(nix eval --raw "${FLAKE}#nixosConfigurations.${host}.config.krg.vaultAgent.roleIdFile" 2>/dev/null)" || return 1
  sidfile="$(nix eval --raw "${FLAKE}#nixosConfigurations.${host}.config.krg.vaultAgent.secretIdFile" 2>/dev/null)" || return 1
  rid="$(bao read -field=role_id "auth/approle/role/${rolename}/role-id" 2>/dev/null)" \
    || { echo "  FAILED: ${host} — cannot read role-id for AppRole '${rolename}' (apply terraform/openbao so the role exists)"; return 1; }
  sid="$(bao write -f -field=secret_id "auth/approle/role/${rolename}/secret-id" 2>/dev/null)" \
    || { echo "  FAILED: ${host} — cannot mint secret-id for AppRole '${rolename}'"; return 1; }
  printf '%s' "$rid" | push_root_file "$target" "$ridfile" 0644 || return 1
  printf '%s' "$sid" | push_root_file "$target" "$sidfile" 0600 || return 1
  echo "  staged vault-agent secret-zero for ${host} (AppRole ${rolename})"
}

# Dump on-box failure context when a switch fails, so the cause is visible in the
# CI log instead of needing a live login. READ-ONLY and best-effort: it only reads
# unit/container state (never mutates), and its own failure (e.g. host unreachable)
# never changes the deploy's exit — the caller exits 1 regardless. Surfaces the
# failed systemd units + their journals, and for Docker hosts the container table
# plus logs of any non-Up/unhealthy container (the krg-prod compose stacks fail as a
# unit; the actual cause is in a single container's log — e.g. a mysqld that aborts
# on an unknown flag, which is invisible from `systemctl status` alone).
dump_failure_diagnostics() {
  local target="$1"
  echo "::group::diagnostics: ${target} (read-only)"
  ssh "${sshopts[@]}" "$target" bash -s <<'REMOTE' 2>&1 || echo "  (diagnostics collection failed — host may be unreachable)"
set +e
echo "===== systemctl --failed ====="
sudo systemctl --failed --no-pager
echo
echo "===== journals for failed units (last 80 lines each) ====="
for u in $(systemctl list-units --state=failed --no-legend --plain | awk '{print $1}'); do
  echo "----- $u -----"
  sudo journalctl -u "$u" --no-pager -n 80
  echo
done
if command -v docker >/dev/null 2>&1; then
  echo "===== docker ps -a ====="
  sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}'
  echo
  echo "===== logs of stopped/unhealthy containers (last 60 lines each) ====="
  for c in $(sudo docker ps -a --format '{{.Names}}\t{{.Status}}' | awk -F '\t' '$2 !~ /^Up / || $2 ~ /unhealthy/ {print $1}'); do
    echo "----- $c -----"
    sudo docker logs --tail 60 "$c" 2>&1
    echo
  done
fi
REMOTE
  printf '\n::endgroup::\n'
}

# ── exit 4: the generation IS live, a unit just failed to START ──────────────
# `switch-to-configuration` exits 4 when the new configuration activated
# successfully but one or more units failed to start. That is NOT a failed
# deploy, and treating it as one is an AVAILABILITY bug rather than a cosmetic
# one: phases are strictly ordered (ADR 0011), so aborting an early phase blocks
# every later phase. On 2026-07-29 (run 30504137214) a crowdsec flake on
# krg-ldap failed phase 0 and thereby blocked phase 1 — which was carrying the
# e4e-nas Garage config-path fix while S3 was down. A unit that self-healed in
# 50s extended an object-storage outage by an hour.
#
# The recurring offender is crowdsec, and it is structural: its upstream
# ExecStartPre (`crowdsec-setup`) runs `cscli hub update` — a NETWORK call to
# cdn-hub.crowdsec.net — under `set -euo pipefail` on EVERY start, while the same
# activation batch restarts the resolver stack (resolvconf/nscd/sssd). So a DNS
# blip during activation kills crowdsec, `Restart=on-failure` revives it ~50s
# later, and the hub refresh it was doing is a pure optimization (the on-disk hub
# cache is what actually gets loaded, and autoUpdateService refreshes it daily
# anyway). Observed 3x in 8 weeks on krg-ldap alone. Two earlier variants of the
# same class already cost fleet deploys — see nix/modules/security/crowdsec.nix
# (runs 27663630406, 27731137477).
#
# Note nixos-rebuild MISREPORTS this as
#   "error: while running command with remote sudo, did you forget to use --ask-sudo-password?"
# which sends you chasing credentials. It is not a sudo problem; the inner
# failure is reported separately as "returned non-zero exit status 4".
#
# So for an exit-4 failure ONLY, ask the box instead of trusting the exit code:
#   1. is it running the exact generation we just built, and
#   2. are there no failed units left once auto-restarts have settled?
# Both true → WARN and continue. Either false → fall through to the normal abort.
# Every other non-zero exit (eval/build error, unreachable host, activation
# aborted, bootloader failure) stays fatal immediately and is never examined —
# which is why this keys on the exit-4 signature rather than on "any failure".
switch_exit4_recovered() {
  local host="$1" target="$2" want got failed settled=0 i
  # The toplevel we just built. If this cannot be evaluated we have no way to
  # prove the generation is current, so refuse to excuse the failure.
  if ! want="$(nix eval --raw "${FLAKE}#nixosConfigurations.${host}.config.system.build.toplevel" 2>/dev/null)"; then
    echo "  exit 4: cannot evaluate expected toplevel for ${host} — treating as a real failure"
    return 1
  fi
  if ! got="$(ssh "${sshopts[@]}" "$target" readlink -f /run/current-system 2>/dev/null)"; then
    echo "  exit 4: cannot read /run/current-system on ${target} — treating as a real failure"
    return 1
  fi
  if [[ "$got" != "$want" ]]; then
    echo "  exit 4 but ${host} is NOT on the generation we built — real failure:"
    echo "      built:   ${want}"
    echo "      running: ${got}"
    return 1
  fi
  # Give Restart=on-failure time to settle before judging. crowdsec recovers in
  # ~50s; poll up to 120s so a slower dependent chain still gets its chance.
  for ((i = 0; i < 24; i++)); do
    if ! failed="$(ssh "${sshopts[@]}" "$target" \
        'systemctl list-units --state=failed --no-legend --plain | awk "{print \$1}"' 2>/dev/null)"; then
      echo "  exit 4: lost contact with ${target} while waiting for units to settle — treating as a real failure"
      return 1
    fi
    if [[ -z "${failed//[[:space:]]/}" ]]; then
      settled=1
      break
    fi
    sleep 5
  done
  if ((settled)); then
    echo "  exit 4: ${host} is on the generation we built and has NO failed units — a unit"
    echo "          failed to start during activation and then recovered. Continuing."
    return 0
  fi
  echo "  exit 4 and ${host} STILL has failed units after 120s — real failure:"
  local u
  while IFS= read -r u; do
    [[ -n "$u" ]] && echo "      ${u}"
  done <<< "$failed"
  return 1
}

# Fail-fast: stop on the first failed host. Order is dependency-first (vault/AD
# before the services that use them), so a failure early means the dependents
# would be deploying against a broken base — don't.
for host in "${ORDER[@]}"; do
  [[ -n "${WANT[$host]:-}" ]] || continue
  target="$(target_for "$host")"
  echo "::group::nixos-rebuild switch ${host} (${target})"
  # Stage the OEC archive BEFORE the switch so this rebuild's oec-install
  # oneshot finds it and enrolls on the same run.
  if ! stage_oec "$target"; then
    echo "FAILED: ${host} — could not stage OEC installer; stopping"
    printf '\n::endgroup::\n'
    exit 1
  fi
  # Stage the vault-agent secret-zero (no-op unless the host uses krg.vaultAgent) so
  # openbao-agent can authenticate on this same switch.
  if ! stage_vault_secret_zero "$host" "$target"; then
    echo "FAILED: ${host} — could not stage vault-agent secret-zero; stopping"
    printf '\n::endgroup::\n'
    exit 1
  fi
  # Capture the output as well as the status: nixos-rebuild does not propagate
  # switch-to-configuration's exit 4 as its OWN exit code (it wraps the remote
  # command and reports "returned non-zero exit status 4" in its message), so the
  # exit-4 signature has to be detected in the text. tee keeps the CI log intact.
  _switch_log="$(mktemp)"
  set +e
  nixos-rebuild switch \
        --flake "${FLAKE}#${host}" \
        --target-host "${target}" \
        --build-host  "${target}" \
        --sudo 2>&1 | tee "$_switch_log"
  _switch_rc=${PIPESTATUS[0]}
  set -e
  if ((_switch_rc != 0)); then
    if { ((_switch_rc == 4)) || grep -q 'returned non-zero exit status 4' "$_switch_log"; } \
       && switch_exit4_recovered "$host" "$target"; then
      echo "  WARN: ${host} — a unit failed to start during activation but self-recovered;" >&2
      echo "        the built generation is live, so continuing (see exit-4 note above)." >&2
    else
      rm -f "$_switch_log"
      echo "FAILED: ${host} — stopping; remaining hosts not deployed"
      printf '\n::endgroup::\n'
      dump_failure_diagnostics "$target"
      exit 1
    fi
  fi
  rm -f "$_switch_log"
  echo "OK: ${host}"
  # Re-run the vault-agent so a ROTATED secret (the KV value changed, but the agent's
  # unit didn't, so `switch` left the oneshot alone) is re-rendered, and each render's
  # reloadCommand fires for the consumer whose secret actually changed. Best-effort: a
  # failed re-render leaves the prior /run files in place (consumers keep the last-good
  # secret), so WARN rather than fail the deploy.
  if [[ "$(nix eval "${FLAKE}#nixosConfigurations.${host}.config.krg.vaultAgent.enable" 2>/dev/null || echo false)" == "true" ]]; then
    if ssh -o BatchMode=yes "$target" sudo systemctl restart openbao-agent; then
      echo "  re-rendered vault-agent secrets on ${host}"
    else
      echo "  WARN: vault-agent re-render failed on ${host} — consumers keep prior secrets; check 'systemctl status openbao-agent'" >&2
    fi
  fi

  # Reclaim disk NOW rather than waiting for the daily/weekly GC timers: this switch
  # just added a system generation and (on compose hosts) the compose 'up' pulled new
  # images, leaving the superseded closure + old image layers on disk. On the small
  # server VMs that churn is exactly what filled krg-prod's 63 GB root and took
  # authentik down (2026-07-19). We START THE ON-HOST UNITS rather than run gc inline,
  # so the retention windows stay single-source-of-truth in the flake (nix.gc
  # `--delete-older-than`, krg.docker.pruneImagesOlderThan) — this just makes them run
  # on the deploy that created the garbage. BEST-EFFORT: the switch already succeeded,
  # so a GC hiccup only WARNs (never fails the deploy); `timeout` caps a slow/hung
  # collection (the unit keeps running on-box, we just stop waiting). Set DEPLOY_SKIP_GC=1
  # to skip (e.g. a quick single-host manual deploy where the extra minute isn't wanted).
  if [[ "${DEPLOY_SKIP_GC:-0}" != "1" ]]; then
    if timeout 600 ssh -o BatchMode=yes "$target" sudo systemctl start nix-gc.service; then
      echo "  GC: nix-gc done on ${host}"
    else
      echo "  WARN: nix-gc failed/timed out on ${host} (non-fatal); check 'systemctl status nix-gc'" >&2
    fi
    # docker-image-prune.service only exists on docker hosts (krg.docker.enable).
    if [[ "$(nix eval "${FLAKE}#nixosConfigurations.${host}.config.krg.docker.enable" 2>/dev/null || echo false)" == "true" ]]; then
      if timeout 600 ssh -o BatchMode=yes "$target" sudo systemctl start docker-image-prune.service; then
        echo "  GC: docker-image-prune done on ${host}"
      else
        echo "  WARN: docker-image-prune failed/timed out on ${host} (non-fatal); check 'systemctl status docker-image-prune'" >&2
      fi
    fi
  fi
  printf '\n::endgroup::\n'
done
