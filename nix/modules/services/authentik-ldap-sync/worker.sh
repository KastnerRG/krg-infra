# Invoked by the host unit, never with arguments supplied by the roster.
# Queue contents are ignored; the marker grants only one fixed reconciliation.
set -euo pipefail

queue_dir=$1
processing=$2
shift 2

# Moving the request before syncing lets a write DURING sync queue another run.
# Keep processing on failure so systemd retries, including after a worker crash.
if [[ ! -e "$processing" && ! -L "$processing" ]]; then
  if [[ ! -e "$queue_dir/pending" && ! -L "$queue_dir/pending" ]]; then
    exit 0
  fi
  mv -T -- "$queue_dir/pending" "$processing"
fi

"$@"
rm -f -- "$processing"
