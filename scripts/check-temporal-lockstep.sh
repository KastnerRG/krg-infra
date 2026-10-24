#!/usr/bin/env bash
# Fail if temporalio/server and temporalio/admin-tools (temporal-schema) are pinned to
# different MAJOR.MINOR.PATCH in compose.temporal.yml.
#
# admin-tools carries the schema the server expects, so a server bumped alone starts on a
# schema nobody migrated. Renovate groups the two, but its pairing depends on how each
# repo tags (1.29's admin-tools tags carried a CLI suffix that silently split them), so
# the invariant is checked here, where any PR that breaks it goes red.
set -euo pipefail

f="${1:-nix/docker-compose/krg-prod/compose.temporal.yml}"
version_of() {
  grep -oE "image: temporalio/$1:[0-9]+\.[0-9]+\.[0-9]+" "$f" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' || true
}
server=$(version_of server)
tools=$(version_of admin-tools)

if [[ -z $server || -z $tools ]]; then
  echo "FAIL: could not find both temporalio/server and temporalio/admin-tools pins in $f" >&2
  exit 1
fi
if [[ $server != "$tools" ]]; then
  echo "FAIL: temporalio/server $server and temporalio/admin-tools $tools must be the same version ($f)" >&2
  exit 1
fi
echo "ok: temporal server + admin-tools both $server"
