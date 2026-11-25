#!/usr/bin/env bash
# Runs after the mandatory post-Authentik rerender. A reload uses Compose's
# configuration hash to RECREATE the backend with the new env_file values.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "${REPO_ROOT}/deploy/lib.sh"
target="$(target_for krg-prod)"
ssh "${sshopts[@]}" "$target" sudo /run/current-system/sw/bin/krg-roster-invitations-deploy
ssh "${sshopts[@]}" "$target" sudo /run/current-system/sw/bin/krg-roster-invitations-check
