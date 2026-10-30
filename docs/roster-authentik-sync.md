# Roster-triggered Authentik LDAP sync

The roster queues an Authentik reconciliation after successful LDAP writes.
This uses the same `ak ldap_sync krg-samba-ad` command as
`deploy/deploy-authentik-sync.sh`, against the existing `authentik_worker` container.
Authentik's normal schedule remains enabled as a fallback. No Terraform changes,
new API tokens, OpenBao secrets, or public webhook endpoints are needed.

## Flow

1. The roster tracks successful LDAP add/modify/delete operations in its shared
   client layer. Reads and unchanged group membership do not trigger syncs.
2. After the operation finishes (including partial failure), it exclusively creates
   an empty file at `LDAP_CHANGE_SIGNAL_PATH`. The file contains no user data.
3. Compose mounts only `/run/krg/authentik-ldap-sync/requests` into the roster at
   `/run/ldap-change`. The directory is private to UID 1001, the production image's
   appuser. An existing pending request coalesces additional edits.
4. `roster-authentik-sync.path` starts the host service. After a five-second batching
   window, the service moves the marker into the root-owned parent directory and
   runs the fixed sync command. Marker contents never select a command or source.
5. Successful sync removes the in-progress marker. A new LDAP write during sync
   creates a separate pending marker, causing another pass. A failed/crashed worker
   keeps its in-progress marker and retries after 30 seconds.

Only the host service accesses Docker. The roster gets neither the Docker socket
nor an Authentik administrative credential. Browser input cannot configure the
path, container, or source. Other trusted local LDAP writers can reuse the same
signal mechanism if explicitly granted access; changes made outside these writers
still depend on Authentik's scheduled sync.

Queue files live in `/run`; a host reboot clears them. The ordinary Authentik sync
schedule remains the recovery path for a lost signal or missing mount. A failure
to queue is logged as `[ldap-change]` without making a committed LDAP write appear
to have failed. A queued request means reconciliation was requested, not completed.
Existing browser sessions, session-cached roles and previously issued OIDC tokens
are not invalidated by this sync; normal token/session renewal still applies.

## Deploy

1. Build the matching roster revision containing `services/ldap-change.ts`. Leave
   the normal backend running until the new image is ready.
2. Deploy the `krg-prod` NixOS configuration through the normal infra workflow. It
   creates the queue directory, installs/enables the path/service units and supplies
   the Compose mount and `LDAP_CHANGE_SIGNAL_PATH=/run/ldap-change/pending` setting.
3. Recreate the roster backend with the systemd-managed Compose configuration so
   it receives that mount and environment. Plain `docker restart` does not add them.
   Do not use an old override store path copied from an earlier deployment.
4. Check the units and mount without printing secrets:

   ```sh
   sudo systemctl status roster-authentik-sync.path --no-pager
   sudo docker exec e4e-roster-backend-1 node -e '
     const fs = require("fs");
     const path = require("path");
     fs.accessSync(path.dirname(process.env.LDAP_CHANGE_SIGNAL_PATH), fs.constants.W_OK);
     console.log("LDAP sync signal directory is writable");
   '
   ```

5. Make a real group/profile/expiration change through the roster, then check:

   ```sh
   sudo journalctl -u roster-authentik-sync.service --since '5 minutes ago' --no-pager
   ```

   Confirm the updated user/group in Authentik. Allow the batching window plus the
   duration of a full LDAP-source sync. The service is normally inactive between
   requests; the `.path` unit should stay active. Use `systemctl start
   roster-authentik-sync.service` to retry existing pending work, not the worker
   script directly.

Deploying infra before the application hook is harmless: no writes produce signals
yet. Running the new application without the configured mount leaves the hook
disabled by default, or logs a queue error if the path was explicitly set.

## Validation

The roster's `test/ldap-change.test.ts` covers actual shared-client write tracking,
no-op and failed writes, partial failures, unbind failures, batching, mount failure
and symlink safety. The host worker tests cover retry, concurrent changes, ignored
marker contents and safe unlinking of symlinks:

```sh
python3 -m pytest nix/modules/services/authentik-ldap-sync/test_worker.py -q
```
