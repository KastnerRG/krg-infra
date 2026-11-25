# shellcheck shell=bash
# Packaged as krg-roster-invitations-deploy; never edits runtime secrets.
: "${ROSTER_RUNTIME_OVERRIDE:?Runtime Compose override is required}"
directory=/var/lib/krg/e4e-roster
roster_git() { git -c "safe.directory=$directory" -C "$directory" "$@"; }
if [[ "$(roster_git branch --show-current)" != main ]] || \
   [[ -n "$(roster_git status --porcelain)" ]]; then
  echo "ERROR: roster checkout must be clean and on main before automated deployment." >&2
  exit 1
fi
# Fetch the reviewed public source explicitly, without depending on root's SSH
# credentials or an operator's origin configuration. Never reset/stash a checkout.
roster_git fetch https://github.com/UCSD-E4E/E4E-Roster-V3.git main
if ! roster_git merge-base --is-ancestor HEAD FETCH_HEAD; then
  echo "ERROR: roster checkout has local commits; refusing to deploy unreviewed code." >&2
  exit 1
fi
if ! roster_git cat-file -e FETCH_HEAD:backend/src/ui/collab.tsx; then
  echo "ERROR: merge the roster collaborator-management PR before deploying this feature." >&2
  exit 1
fi
roster_git merge --ff-only FETCH_HEAD
docker compose --project-directory "$directory" \
  --env-file "$directory/.env" --env-file /run/krg/roster/compose.env \
  -f "$directory/docker-compose.yml" -f "$ROSTER_RUNTIME_OVERRIDE" build backend
systemctl reload e4e-roster.service
