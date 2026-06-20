# Proxmox VE authentication (Authentik LDAP outpost)

Login to the Proxmox web UI **and the Proxmox mobile/CLI apps** uses a PVE **LDAP
realm** bound to an **Authentik LDAP outpost** (not raw krg-ldap, not OIDC). Users
sign in with their KRG.LOCAL account; the group **`proxmox-admins`** is synced into
PVE and granted **Administrator** on `/`. The local **PAM** realm stays break-glass
(`root@pam` / `krg-admin`).

## Why this shape

- **OIDC is out** because the Proxmox apps can't do the browser-redirect flow. LDAP
  is a plain bind, so the apps work.
- **Through Authentik (not raw AD)** because Authentik's LDAP source **flattens
  nested groups**: `Domain Admins` is nested in `proxmox-admins`, and Authentik
  presents the 6 Domain-Admins members as **direct** members of `proxmox-admins`.
  PVE can't expand nesting itself (it reads a group's direct `member` and skips
  sub-groups), so it reads the already-flattened directory the outpost serves. This
  keeps membership clean: drop someone from Domain Admins → Authentik re-syncs →
  gone from `proxmox-admins`, no flatten-job provenance headaches.
- **Authentik stays the lab dashboard** via the provider-less link tile
  (`applications_krg.tf`); the outpost is the auth backend.

## Layers

- **terraform/authentik/proxmox_ldap.tf** — the `authentik_provider_ldap`, its
  application, a dedicated **LDAP outpost**, the read-only bind service account
  `svc-pve-ldap` (+ its `search_full_directory` permission), and the bind creds
  written to `secret/krg-prod/proxmox-ldap-bind`.
- **nix/docker-compose/krg-prod/compose.authentik.yml** — the `authentik_ldap`
  outpost container (`ghcr.io/goauthentik/ldap`), publishing **6636 (LDAPS)** /
  3389. Its token renders from OpenBao via `krg.vaultAgent`
  (`authentik-ldap-outpost-token.env`).
- **terraform/openbao** — `krg-deploy` may read/write `krg-prod/proxmox-ldap-bind`
  (authentik-managed set).
- **ansible/roles/pve_ldap** — configures the PVE LDAP realm on fabricant, syncs,
  ACLs the synced group, runs a `pve-realm-sync` timer. Materialized creds from
  OpenBao by `deploy/deploy-ansible.sh`.

## ⚠ Bring-up — values that can only be confirmed against the running outpost

The exact tree/attributes Authentik's LDAP outpost serves, the bind/search
permission, and the synced PVE group id are assumptions until validated. Do this
**before** trusting the realm:

1. Apply `terraform/authentik`, then **retrieve the LDAP outpost token** (Admin →
   Outposts → "authentik LDAP Outpost" → View token) and seed it:
   ```
   bao kv put secret/krg-prod/authentik-ldap-outpost-token token=<value>
   ```
2. `nixos-rebuild` krg-prod so the `authentik_ldap` container starts and the token
   renders. Confirm it connects (Admin → Outposts shows it healthy).
3. **`ldapsearch` against the outpost** (from fabricant) with the bind account to
   learn the real tree:
   ```bash
   ldapsearch -H ldaps://krg-prod.ucsd.edu:6636 -o tls_reqcert=never \
     -D "cn=svc-pve-ldap,ou=users,DC=krg,DC=ucsd,DC=edu" \
     -w "$(bao kv get -field=password secret/krg-prod/proxmox-ldap-bind)" \
     -b "DC=krg,DC=ucsd,DC=edu" "(cn=proxmox-admins)"
   ```
   - Confirm the **base_dn**, the **group DN** (`ou=groups,…`), the **username
     attribute** (`cn` vs `uid`), and that `proxmox-admins` lists the 6 members.
   - Adjust `pve_ldap_user_attr` / `pve_ldap_*_filter` / `pve_ldap_group_dn` in the
     role to match, if needed.
   - If the search returns *nothing*, the bind account lacks the search permission —
     check the `authentik_rbac_permission_user` codename
     (`authentik_providers_ldap.search_full_directory`) applied cleanly.
4. **Firewall:** 6636 is published on all interfaces and bypasses the in-guest
   firewall (Docker DNAT via FORWARD). Restrict the source to fabricant
   (137.110.161.98) with a `DOCKER-USER`/nftables FORWARD rule on krg-prod — the
   same open item as dcgm 9400 (CLAUDE.md "Docker published-port firewall bypass").

## Apply

1. `terraform/authentik` apply → provider/app/outpost/service-account + bind secret.
2. Seed the outpost token (above) → `nixos-rebuild` krg-prod (container up).
3. Validate with `ldapsearch` (above); fix any ⚠ filter/attr mismatch.
4. `deploy/deploy-ansible.sh` → the PVE LDAP realm + sync + ACL. After the first
   sync, confirm the synced group id and set `pve_ldap_admin_pve_group` if it isn't
   `proxmox-admins-krg`:
   ```bash
   pveum realm list                # 'krg', type ldap
   pveum group list                # the synced group id
   pveum user list | grep @krg     # the 6 members
   pveum acl list | grep proxmox   # / Administrator -> <synced group>
   ```
5. Log in — realm `krg`, KRG.LOCAL username + password, in the browser and the app.

## Migration cleanup (from the raw-AD-realm attempt)

The `pve_ldap` role deletes any leftover `krg` realm of the wrong type (`ad`) and
the old OIDC `authentik` realm automatically. By hand, retire the raw-AD bind
account if it was created: delete `svc-pve` in AD and remove
`secret/krg-prod/pve-ad-bind` from OpenBao (both superseded by the Authentik
`svc-pve-ldap` service account). The stale local PVE group `proxmox-admins` (if the
AD-realm sync ever created one) — confirm vs the synced id before deleting.

## Notes

- `verify 0` (PVE) + `tls_reqcert=never` (ldapsearch): LDAPS encrypts but doesn't
  verify the outpost cert until the lab CA is trusted on fabricant. Flip
  `pve_ldap_verify: true` (+ capath / the outpost cert) once it is.
- Rotating the bind password: re-run `terraform/authentik` (regenerates
  `random_password.svc_pve_ldap` → updates the Authentik account + the vault secret),
  then the Ansible leg re-pushes it to the realm.
- MFA is **off** (password-only). To require it later, set `mfa_support = true` on
  the LDAP provider (users then append a TOTP code / use an app-password).
