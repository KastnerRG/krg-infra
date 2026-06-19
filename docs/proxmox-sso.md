# Proxmox VE web-UI SSO (Authentik OpenID Connect)

Single sign-on for the Proxmox VE web UI (`https://fabricant.ucsd.edu:8006`) via
Authentik, so hypervisor admins log in with their KRG.LOCAL AD account instead of
a PVE-local password. Greenfield — no prior PVE OIDC config is migrated.

The local **PAM** realm stays the **default** login realm: SSO is opt-in via the
realm dropdown on the login screen, and the break-glass `root@pam` / `krg-admin`
accounts always work. A directory or Authentik outage therefore can never lock
admins out of the hypervisor.

## Layers

Three IaC layers, applied in this order (each consumes the previous):

1. **`terraform/authentik/`** — the OIDC client.
   - `applications_krg.tf`: the `proxmox` OAuth2 provider + application
     (RS256-signed; PVE verifies the ID token against `jwks_uri`), plus the
     `proxmox_groups` scope mapping.
   - `vault_secrets.tf`: writes the minted `client_id`/`client_secret`/`issuer_url`
     to OpenBao at **`secret/krg-prod/proxmox-oidc`**.
   - Icon: `nix/docker-compose/krg-prod/authentik/media-icons/proxmox.svg`.
2. **`terraform/openbao/`** — `main.tf` enumerates `krg-prod/proxmox-oidc` in
   `authentik_managed_secrets`, so the `krg-deploy` AppRole may write it (from the
   authentik apply) and read it (for the ansible apply). Least-privilege (#187).
3. **`ansible/roles/pve_oidc/`** — configures the PVE OpenID Connect realm on
   fabricant (wired into the `proxmox` play in `playbooks/site.yml`). The client
   secret is **not** in git: `deploy/deploy-ansible.sh` AppRole-reads it from
   OpenBao at apply time and passes it as `pve_oidc_client_secret` (fabricant has
   no vault-agent — same materialize-from-OpenBao model as the Synology roles).

## Permission model

AD group **"Proxmox Admins"** (`spec/krg-ad/groups.yml`) is the gate. On every
login PVE reads the OIDC `groups` claim and **overwrites** the user's PVE group
membership (PVE 8.2 *group-sync*, realm `--groups-claim groups --groups-overwrite
1`). The `pve_oidc` role pre-creates the PVE group **`proxmox-admins`** with the
**`Administrator`** role on `/`, so a synced member becomes a full PVE admin.

- PVE group ids can't contain spaces, so the Authentik `proxmox_groups` scope maps
  the AD name `"Proxmox Admins"` → the PVE-safe id `proxmox-admins` (it does *not*
  emit raw AD group names). To grant another AD group a PVE role later: add the
  mapping to `proxmox_groups` **and** a matching pre-created group + ACL in the
  role's defaults/tasks.
- A user who completes SSO but is **not** in "Proxmox Admins" is autocreated
  (`--autocreate 1`) as `<user>@authentik` with **no ACL** — they can authenticate
  but see and do nothing. Membership in the AD group is the only thing that grants
  access.

### Nested-group caveat (Domain Admins → Proxmox Admins)

The plan is to nest **"Domain Admins"** inside "Proxmox Admins" so the hypervisor
SSH admins get the UI too. This only works if the Authentik LDAP source **flattens
nested membership** — `request.user.ak_groups` (what `proxmox_groups` reads) is the
user's *direct* Authentik groups. If a Domain Admin doesn't get the
`proxmox-admins` claim after the nest, either the sync isn't expanding nesting or
the nest hasn't synced yet; the reliable fallback is to add the human (or "Domain
Admins") **directly** to "Proxmox Admins" in AD. Verify with the token inspector
(below) before relying on the nest.

## Requirements

- **PVE ≥ 8.2** for realm group-sync (`--groups-claim`/`--groups-overwrite`).
  **fabricant runs Proxmox VE 9** (see `docs/fleet-inventory.md`), so this is
  satisfied. On a pre-8.2 node set `pve_oidc_groups_sync: false` and grant the ACL
  another way.
- fabricant must reach Authentik (`auth.krg.ucsd.edu:443`) outbound for the
  token/JWKS exchange (the cluster.fw `OUT` policy is ACCEPT; no new rule needed).
  Inbound 8006 is already open to the `ucsd`/`ops` IPSets (cluster.fw).
- `/etc/pve/domains.cfg` (the realm) lives on the **cluster** filesystem, so the
  realm, group, and ACL are cluster-wide, not per-node. The realm's redirect URI is
  per-node, though: when a second PVE node joins, add its
  `https://<node>:8006` to `allowed_redirect_uris` in `applications_krg.tf`.

## Apply

```bash
# 1. Authentik: mint the client + write the secret to OpenBao
cd terraform/authentik && tofu apply        # (CD: deploy/deploy-tofu.sh)

# 2. OpenBao policy (only when first adding the path)
cd terraform/openbao  && tofu apply

# 3. PVE realm on fabricant — picks up the secret from OpenBao automatically
ansible-playbook ansible/playbooks/site.yml --tags pve_oidc --check   # dry run
# CD path (materializes the secret from OpenBao for you):
#   DEPLOY ... deploy/deploy-ansible.sh
```

If step 3 runs before step 1 (or without OpenBao AppRole creds), the realm step
**no-ops** — only the `proxmox-admins` group + ACL are created — and logs a `note:`.
Re-run after the secret exists.

## Validate

```bash
# On fabricant:
pveum realm list                       # 'authentik' present, type openid
pveum group list                       # 'proxmox-admins' present
pveum acl list | grep proxmox-admins   # / -> Administrator

# Then in a browser: https://fabricant.ucsd.edu:8006 → Realm: "authentik" →
# log in as a "Proxmox Admins" member → should land with full admin.
```

If login fails with **"Invalid ID token"**, the provider lost its RS256
`signing_key`. If Authentik logs a **redirect_uri mismatch**, confirm the exact
origin PVE sends (`https://fabricant.ucsd.edu:8006`, no trailing slash) matches the
`allowed_redirect_uris` strict entry.

## Rotation

Re-running `terraform/authentik` rotates the `client_secret` in OpenBao; the next
`deploy-ansible.sh` re-pushes it to the realm (`pveum realm modify --client-key`).
The role reconciles the realm unconditionally for exactly this reason — it can't
read the stored secret back to diff it.
