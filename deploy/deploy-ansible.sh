#!/usr/bin/env bash
# Apply the Ansible layer from the control node (krg-deploy).
#
# By default this mirrors the nightly `ansible-apply` timer in
# nix/hosts/krg-deploy/default.nix: it runs ONLY playbooks/site.yml (the
# Proxmox/Debian hypervisor hosts). site.yml connects to fabricant as root over
# SSH (push mode — see ansible/inventory/hosts.yml).
#
# The Synology NAS playbook is OPT-IN (DEPLOY_SYNOLOGY=true) and OFF by default:
# its declarative sync DELETES anything not in spec, and bring-up has gates
# (pre-flight live captures, .dss backup, `--check --diff` first) that must run
# before any unattended apply — see docs/e4e-nas-dsm.md. Do not flip it on until
# the NAS bring-up is complete.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Host-key checking is intentionally NOT overridden here — ansible/ansible.cfg sets
# host_key_checking = True, and we keep that (krg-deploy's known_hosts must include
# the fleet host keys, provisioned out-of-band). Don't weaken it to unblock a run.
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/var/lib/krg-admin/.ssh/id_ed25519}"
[[ -f "$DEPLOY_SSH_KEY" ]] && export ANSIBLE_PRIVATE_KEY_FILE="${ANSIBLE_PRIVATE_KEY_FILE:-$DEPLOY_SSH_KEY}"

echo "::group::ansible site.yml (Proxmox hosts)"
(
  cd "${REPO_ROOT}/ansible"
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook playbooks/site.yml
)
echo "::endgroup::"

if [[ "${DEPLOY_SYNOLOGY:-false}" == "true" ]]; then
  echo "::group::ansible synology (e4e-nas)"
  (
    cd "${REPO_ROOT}/ansible/synology"
    ansible-playbook playbook.yml
  )
  echo "::endgroup::"
else
  echo "skip synology: DEPLOY_SYNOLOGY!=true (NAS bring-up gates not cleared — see docs/e4e-nas-dsm.md)"
fi
