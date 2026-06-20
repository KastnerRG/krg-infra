# OpenBao bring-up (krg-vault)

Day-0 procedure to initialize, unseal, and structure the OpenBao secrets manager
on **krg-vault** (`137.110.161.123`, API at `https://krg-vault.ucsd.edu:8200`).
This is the step two other runbooks list as a prerequisite
([krg-deploy-ansible-setup.md](krg-deploy-ansible-setup.md),
[garage-ui-bringup.md](garage-ui-bringup.md)) — both assume "OpenBao initialized +
unsealed" but neither documents it.

The host config is [`nix/hosts/krg-vault/default.nix`](../nix/hosts/krg-vault/default.nix):
`services.openbao` with **Raft** storage at `/var/lib/openbao` (node `krg-vault-1`),
a TLS listener on `0.0.0.0:8200` using the Let's Encrypt cert (nginx serves the
HTTP-01 challenge on `:80`), the UI on, and `VAULT_ADDR` exported fleet-wide so the
`bao` CLI talks to the local instance over TLS. The `:8200` API is firewalled to
`sealab` + `ops` + `machines`.

> **Secret hygiene:** the unseal keys and root token printed by `init` are the
> keys to every lab secret. Escrow them out-of-band (password manager / sealed
> envelope) — **never** commit them, paste them into the repo, or leave them in
> shell history.

## 1. Deploy the host

```bash
nixos-rebuild switch --flake ./nix#krg-vault \
  --target-host krg-admin@krg-vault.ucsd.edu --sudo --ask-sudo-password
```

OpenBao comes up **sealed and uninitialized** — that's expected.

## 2. Initialize (one time, ever)

SSH to krg-vault as `krg-admin`, then:

```bash
bao status                 # Initialized: false, Sealed: true
bao operator init          # prints 5 unseal key shares + 1 root token
```

`init` runs exactly once in the cluster's life. By default it produces 5 Shamir
key shares with a threshold of 3. **Record all five shares and the root token in
the escrow location now** — they are unrecoverable if lost, and `bao` will not
print them again.

## 3. Unseal

OpenBao seals itself on every start. Provide 3 of the 5 shares (any three,
ideally by different people):

```bash
bao operator unseal        # paste share 1
bao operator unseal        # paste share 2
bao operator unseal        # paste share 3
bao status                 # Sealed: false
```

> **This repeats after every reboot / service restart** — OpenBao has no
> auto-unseal configured, so a krg-vault reboot leaves it sealed until someone
> runs three `bao operator unseal`. Anything depending on it (krg-deploy's
> nightly apply, vault-agent on krg-prod) fails closed until then. Auto-unseal
> (transit/KMS) is a future improvement.

## 4. Lay down the structure (OpenTofu)

The mounts, AppRole auth, roles, and policies are **not** created by hand — they
live in [`terraform/openbao/`](../terraform/openbao/README.md). From **krg-deploy**
(or any control node with `tofu`), authenticated with the root token from step 2:

```bash
cd terraform/openbao
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export VAULT_TOKEN="<root token from step 2>"
tofu init && tofu apply
```

This creates the KV-v2 mount at `secret/`, the `approle` auth backend, and the
`krg-deploy` + `krg-prod` roles/policies. See the
[terraform/openbao README](../terraform/openbao/README.md) for what each grants.

## 5. Issue the AppRole credentials

Each consumer authenticates with a `role_id` (non-secret) + `secret_id` (secret).
Read the role_id and mint a secret_id, then place them where the consumer expects.
For **krg-deploy** (paths per [krg-deploy-ansible-setup.md](krg-deploy-ansible-setup.md)):

```bash
bao read    auth/approle/role/krg-deploy/role-id        # -> role_id
bao write -f auth/approle/role/krg-deploy/secret-id     # -> secret_id (one-time view)

# on krg-deploy, as krg-admin:
install -m600 <(printf '%s' "<role_id>")   /var/lib/krg-admin/.secrets/openbao-role-id
install -m600 <(printf '%s' "<secret_id>") /var/lib/krg-admin/.secrets/openbao-secret-id
```

The `krg-deploy` policy can itself mint secret_ids for the other roles
(`auth/approle/role/+/secret-id`), so it can bootstrap `krg-prod`'s vault-agent.

## 6. Seed secrets, then apply the dependent tofu targets

Populate the KV paths the other workspaces read (e.g.
`secret/krg-deploy/authentik-admin-token`, `secret/krg-prod/grafana-admin`,
`secret/e4e-nas/*`), then apply in **dependency order** — OpenBao must hold the
secrets before the readers run, and Authentik writes OIDC secrets that Grafana
reads:

```
openbao  →  authentik  (writes generated OIDC client secrets back into OpenBao)
         →  grafana    (reads grafana-oidc from OpenBao)
         →  e4e-nas    (independent)
```

See each target's README under [`terraform/`](../terraform/README.md) for its
required vars and tokens.

## 7. Seed the krg-prod stack secrets (Authentik / Grafana / Vaultwarden)

The Authentik, Grafana, and Vaultwarden compose services no longer read
hand-placed `/var/lib/krg/krg-prod/.secrets/*` files — `krg.vaultAgent`
(`nix/hosts/krg-prod/default.nix`) renders them from OpenBao to `/run` at boot,
and the krg-prod compose stack `requires` the agent (fails closed if bao is
sealed/unreachable). The agent renders **all** paths in one oneshot, so every
path below must exist before deploying or the agent exits non-zero and the
stack won't start.

Some values already exist (skip them): `secret/krg-prod/grafana-admin`
(field `password`, also used by the grafana tofu provider) and the
authentik-generated `secret/krg-prod/authentik-managed/vaultwarden-oidc`.

The rest are **LIVE** values — seed them at their *current* values, do **not**
regenerate (rotating `secret_key` invalidates Authentik sessions; rotating the
DB passwords breaks the running Postgres role; the outpost token must match the
one Authentik issued). Read the current values from the existing `.secrets/`
files on krg-prod, then write them once:

```bash
# On krg-prod, as the operator (these read live secret files — keep them off
# shell history; the heredoc/`<` forms below avoid arg capture):
cd /var/lib/krg/krg-prod/.secrets

# Authentik — SECRET_KEY + the authentik DB-role password live together in
# authentik_admin_password.env (KEY=VALUE lines); the superuser password is the
# bare-value file authentik_postgres_admin_password.txt.
bao kv put secret/krg-prod/authentik \
  secret_key="$(grep '^AUTHENTIK_SECRET_KEY=' authentik_admin_password.env | cut -d= -f2-)" \
  postgresql_password="$(grep '^AUTHENTIK_POSTGRESQL__PASSWORD=' authentik_admin_password.env | cut -d= -f2-)" \
  postgres_admin_password="$(cat authentik_postgres_admin_password.txt)"

# Authentik embedded-outpost token (the value in authentik_traefik_token.env,
# AUTHENTIK_TOKEN=...). If lost, re-read it in Authentik: Admin → Outposts → View token.
bao kv put secret/krg-prod/authentik-outpost-token \
  token="$(grep '^AUTHENTIK_TOKEN=' authentik_traefik_token.env | cut -d= -f2-)"

# Vaultwarden /admin argon2 hash (the ADMIN_TOKEN line in vaultwarden.env).
bao kv put secret/krg-prod/vaultwarden \
  admin_token="$(grep '^ADMIN_TOKEN=' vaultwarden.env | cut -d= -f2-)"
```

After seeding, deploy krg-prod. Once the stack is healthy on bao-rendered
secrets, the `.secrets/` files for these three are dead and can be removed
(keep `outline_secrets.env` + `mlflow.env` until those stacks are migrated).

## Backup & recovery

- **Raft snapshot** (the whole datastore, encrypted): `bao operator raft snapshot
  save krg-vault-$(date +%F).snap`. Restore onto a fresh node with
  `bao operator raft snapshot restore <file>`. Keep snapshots off-box.
- **After a krg-vault rebuild:** restore the Raft snapshot (or re-init if starting
  clean), then **unseal** (step 3). The unseal shares + root token from step 2 are
  required — losing all of them means re-initializing and re-seeding every secret.
- See [disaster-recovery.md](disaster-recovery.md) for the fleet-wide recovery
  context.
