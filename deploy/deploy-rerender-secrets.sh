#!/usr/bin/env bash
# Re-render a host's krg.vaultAgent secrets AFTER the OpenTofu phase, so secrets
# that OpenTofu GENERATES in phase 3 reach the consumers it can't precede.
#
# Most generated secrets are self-minted early (terraform/secrets, phase 1.5) and
# so already exist when the fail-closed vault-agent renders in phase 2. The lone
# exception is an Authentik OUTPOST token: authentik_token.key is provider-read-only
# (Authentik mints it), so it can only exist once the outpost does — i.e. when
# terraform/authentik applies in phase 3, AFTER phase 2. Its render is therefore the
# one allowed to be empty at phase 2 (krg.vaultAgent … errorOnMissingKey = false),
# and THIS step closes the loop: re-running openbao-agent after phase 3 re-renders
# the now-present tokens (proxy + ldap outposts), and each render's reloadCommand
# (`docker restart authentik_proxy` / `authentik_ldap`) fires because the content
# changed empty → token — so a from-scratch deploy converges the outposts in a
# single run.
#
# Best-effort by design: a host that's down / has no krg.vaultAgent / whose agent
# fails just WARNs (the next deploy re-renders). It never fails the deploy — every
# fail-closed secret already rendered in phase 2; this only fills the post-phase-3
# gap. Idempotent: in steady state the token already exists, the render is
# unchanged, no reloadCommand fires, nothing restarts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"

# Hosts to re-render (default: krg-prod, the only krg.vaultAgent host that consumes
# an OpenTofu-generated outpost token). Override with DEPLOY_RERENDER_HOSTS.
read -r -a HOSTS <<< "${DEPLOY_RERENDER_HOSTS:-krg-prod}"

rc=0
for host in "${HOSTS[@]}"; do
  target="$(target_for "$host")"
  enabled="$(nix eval "${FLAKE}#nixosConfigurations.${host}.config.krg.vaultAgent.enable" 2>/dev/null || echo false)"
  if [[ "$enabled" != "true" ]]; then
    echo "skip: ${host} does not use krg.vaultAgent"
    continue
  fi
  echo "::group::re-render vault-agent on ${host} (${target})"
  if ssh "${sshopts[@]}" "$target" sudo systemctl restart openbao-agent; then
    echo "OK: re-rendered vault-agent secrets on ${host} (outpost token converged if phase 3 minted it)"
  else
    echo "WARN: vault-agent re-render failed on ${host} — outpost token will land on the next deploy; check 'systemctl status openbao-agent'" >&2
  fi
  printf '\n::endgroup::\n'
done

exit "$rc"
