# Proxmox VE authentication (Active Directory realm)

Login to the Proxmox web UI **and the Proxmox mobile/CLI apps** uses a native PVE
**Active Directory realm** against the lab DC (`krg-ldap`, `KRG.LOCAL`). Users sign
in with their KRG.LOCAL account; the AD group **`proxmox-admins`** is synced into
PVE and granted **Administrator** on `/`. The local **PAM** realm stays as
break-glass (`root@pam` / `krg-admin`).

> **Why not OIDC/Authentik?** The Proxmox apps (and any non-browser client) can't do
> the OIDC redirect flow, and PVE's AD realm does group→role sync natively — no
> Authentik claim mapping (which, on goauthentik 2026.5, hit a chain of
> grant_types / `ak_groups` / evaluator quirks). Authentik still shows a **link
> tile** for Proxmox (the lab dashboard) — clicking it opens the PVE UI — but it is
> **not** in the auth path.

## Layers

- **`ansible/roles/pve_ad/`** — configures the `krg` AD realm on fabricant
  (`pveum realm add --type ad …`), runs `pveum realm sync`, ACLs the synced admin
  group, and installs a `pve-realm-sync` systemd timer. Wired into the `proxmox`
  play in `playbooks/site.yml`. The bind password is materialized from OpenBao by
  `deploy/deploy-ansible.sh` (fabricant has no vault-agent).
- **`spec/krg-ad/`** — `groups.yml` declares the space-free `proxmox-admins` group;
  `service-accounts.yml` declares the read-only bind account **`svc-pve`**.
- **`terraform/openbao/`** — `krg-deploy` may **read** `secret/krg-prod/pve-ad-bind`
  (the svc-pve password). The old `krg-prod/proxmox-oidc` managed path is removed.
- **`terraform/authentik/`** — the `proxmox` application is now a **provider-less
  link tile** (icon + launch URL only). The OIDC provider/scopes/secret are removed.

## Realm config (what the role sets)

```
pveum realm add krg --type ad \
  --domain KRG.LOCAL --server1 krg-ldap.ucsd.edu \
  --mode ldaps --verify 0 \                # 636 confirmed open; verify off until the lab CA is trusted
  --base_dn DC=KRG,DC=LOCAL \
  --bind_dn CN=svc-pve,CN=Users,DC=KRG,DC=LOCAL --password <svc-pve> \
  --default 1 \                            # pre-select AD; PAM stays in the dropdown
  --filter '(&(objectCategory=person)(objectClass=user)(memberOf=CN=proxmox-admins,CN=Users,DC=KRG,DC=LOCAL))' \
  --group_filter '(&(objectClass=group)(cn=proxmox-admins))' \
  --sync-defaults-options enable-new=1
```

The sync filters scope PVE to the admin group + its members so the whole directory
isn't mirrored. Login binds as the **end user** (not svc-pve); svc-pve is only for
the directory search during sync.

## Prerequisites / operator steps (one-time)

1. **AD group** — rename the old `Proxmox Admins` group to **`proxmox-admins`** in
   AD (preserves membership), or create it and move members. PVE group ids can't
   contain spaces, so a spaced name is skipped on sync. Add hypervisor admins as
   **direct** members (PVE sync does not expand nested groups).
2. **Bind account** — create `svc-pve` in AD (read-only is enough; a normal
   authenticated principal can read users/groups) and seed its password:
   ```
   bao kv put secret/krg-prod/pve-ad-bind password=<svc-pve password>
   ```
3. **OpenBao policy** — apply the `openbao` target (privileged) so `krg-deploy` can
   read that path: `TOFU_TARGETS=openbao TOFU_OPENBAO_TOKEN=… ./deploy/deploy-tofu.sh`.
4. **Deploy** — `deploy/deploy-ansible.sh` (or the fleet deploy) configures the
   realm, runs the first sync, and ACLs the group.

## Bring-up verification (⚠ can't be dry-run from CI)

```bash
# on fabricant:
pveum realm list                       # 'krg', type ad
pveum realm sync krg --dry-run 1       # see what would sync; confirm proxmox-admins + members appear
pveum group list                       # find the synced group id (expected: proxmox-admins-krg)
pveum acl list | grep -i proxmox       # '/  Administrator  group  <synced-group>'
```

If the synced group id is **not** `proxmox-admins-krg`, set
`pve_ad_admin_pve_group` in the role to the real id and re-run (the ACL targets it).
If a member doesn't sync, check the `--filter` (member resolution / nested groups).

Then in a browser: `https://fabricant.ucsd.edu:8006` → realm **krg** → log in with a
`proxmox-admins` member → full admin. In the **app**: add the server, realm `krg`,
same credentials.

## Notes

- `--verify 0` encrypts (LDAPS) but does not verify the DC cert. Once the lab CA
  root is trusted on fabricant, set `pve_ad_verify: true` (+ `--capath`).
- `pve_ad_server2` is reserved for the second DC (krg-ldap SPOF removal); set it
  when that DC exists so realm sync/login fail over.
- Rotating the svc-pve password: update `secret/krg-prod/pve-ad-bind` and re-run the
  Ansible leg — the realm reconcile re-pushes `--password` every run.
