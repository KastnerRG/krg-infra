# shellcheck shell=bash
# Compose labels stay stable when container names change. Require exactly one
# running worker; never execute a request-supplied container name or command.
set -euo pipefail
docker_host=unix:///var/run/docker.sock
container=$(docker --host "$docker_host" ps \
  --filter label=com.docker.compose.project=krg-prod \
  --filter label=com.docker.compose.service=authentik_worker \
  --filter status=running --format '{{.ID}}')
if [[ ! "$container" =~ ^[a-f0-9]{12,64}$ ]]; then
  echo 'Expected exactly one running krg-prod Authentik worker; sync will retry.' >&2
  exit 1
fi
docker --host "$docker_host" exec -i --env "ROSTER_LDAP_SOURCE=${1:-krg-samba-ad}" "$container" \
  ak shell --command 'exec(__import__("sys").stdin.read(), {"__name__": "__main__"})' < "$SYNC_PROGRAM"
