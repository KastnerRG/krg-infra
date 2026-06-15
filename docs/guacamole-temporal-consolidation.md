# Guacamole + Temporal → krg-prod compose project (one-time cutover)

Guacamole and Temporal used to run as their **own** `krg.composeStacks` entries
(separate Docker Compose projects, `guacamole` and `temporal`), each with its own
`openbao-agent` dependency. That per-stack split was justified as "scoping the bao
blast radius," but the isolation was illusory: every bao-backed service depends on
the **single** `openbao-agent` oneshot, so they already share its fate. The split
only added moving parts.

They are now **include'd into the krg-prod compose project** (`compose.yml`), so the
fleet runs one lab-wide stack with one bao dependency. This is a config-only change
*except* for one thing: Docker Compose namespaces **named volumes by project**, so
folding a service into a new project changes the volume name its data lives under.

## What moves

| Service | Old project / volume | New project / volume | Data |
|---|---|---|---|
| **Guacamole Postgres** | `guacamole` / `guacamole_guacamole_pgdata` | `krg-prod` / `krg-prod_guacamole_pgdata` | **LIVE — must migrate** |
| **Temporal Postgres** | `temporal` / `temporal_temporal_pgdata` | `krg-prod` / `krg-prod_temporal_pgdata` | none yet (Temporal not deployed — nothing to migrate) |

Bind-mounted data is unaffected (it's keyed by host path, not project). Only the
two named Postgres volumes are project-scoped, and only Guacamole's holds live data
(its connection inventory + per-user authz).

## Cutover (run on krg-prod, as the operator, in the deploy window)

Container names are fixed (`guacamole`, `guacd`, `guacamole_postgres`), so the new
krg-prod project can't create them while the old `guacamole` project's containers
still exist. Tear the old project down first, copy the volume, then deploy:

```bash
# 1. Stop the old standalone Guacamole project (removes its containers; the named
#    volume persists — `down` without -v does NOT delete volumes).
sudo systemctl stop guacamole-compose.service     # or: docker compose -p guacamole down

# 2. Copy the live Postgres data into the volume the krg-prod project will use.
#    Same Postgres major (16), so a raw datadir copy is safe (no dump/restore).
docker volume create krg-prod_guacamole_pgdata
docker run --rm \
  -v guacamole_guacamole_pgdata:/from:ro \
  -v krg-prod_guacamole_pgdata:/to \
  alpine sh -c 'cp -a /from/. /to/'

# 3. Deploy the converged config. The krg-prod stack now include's Guacamole +
#    Temporal and brings them up under project `krg-prod`, reusing the volume above.
sudo nixos-rebuild switch --flake ./nix#krg-prod \
  --target-host krg-admin@krg-prod.ucsd.edu --sudo --ask-sudo-password

# 4. Verify Guacamole at https://remote.krg.ucsd.edu (existing connections + logins
#    intact), then reclaim the old volume.
docker volume rm guacamole_guacamole_pgdata
```

If anything looks wrong after step 3, the old volume is still intact — point the
stack back or restore from it. Nothing is destroyed until step 4.

## Notes

- The `openbao-agent` renders are unchanged: Guacamole still reads
  `/run/krg/guacamole/{web,db}.env` and Temporal `/run/krg/temporal/{db,server,ui}.env`.
- `./guacamole/initdb` in `compose.guacamole.yml` now resolves against the krg-prod
  working dir (`/var/lib/krg/krg-prod`), where nix symlinks `guacamole/` → the Nix
  store (see `nix/hosts/krg-prod/default.nix` tmpfiles). The init SQL only runs on a
  *fresh* DB, so the migrated volume above skips it (as intended).
