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
  application, a dedicated **LDAP outpost**, the bind service account `svc-pve-ldap`
  (made a member of the built-in **`authentik Admins`** superuser group so it can
  search the full directory — see the note below on why not the scoped
  `search_full_directory` permission), and the bind creds written to
  `secret/krg-prod/authentik-managed/proxmox-ldap-bind`.
- **terraform/authentik/outpost_tokens.tf** — mints the LDAP outpost's API token in
  IaC (an `authentik_token` for the outpost's service account, `retrieve_key`) and
  writes it to OpenBao at `secret/krg-prod/authentik-managed/ldap-outpost-token`
  (under the krg-deploy write-back glob — no openbao policy change). No manual
  "View token" step.
- **nix/docker-compose/krg-prod/compose.authentik.yml** — the `authentik_ldap`
  outpost container (`ghcr.io/goauthentik/ldap`), publishing **6636 (LDAPS)** /
  3389, its token rendered from OpenBao via `krg.vaultAgent`
  (`authentik-ldap-outpost-token.env`). Because the token is minted in **phase 3**
  (`outpost_tokens.tf`) — AFTER the **phase 2** krg.vaultAgent render — this one
  render is **non-fail-closed** (`errorOnMissingKey = false`): on a from-scratch
  deploy the path is briefly empty (an empty token fails LOUDLY at the outpost, never
  silently), and `deploy/deploy-rerender-secrets.sh` re-renders krg-prod after phase
  3 so it converges in one run. Steady state (token present) is identical to
  fail-closed.
- **terraform/openbao** — `krg-deploy` may read/write `krg-prod/authentik-managed/*`
  (one glob covers proxmox-ldap-bind + every other authentik-generated secret; no
  per-path policy entry, no openbao apply when a new app is added).
- **ansible/roles/pve_ldap** — configures the PVE LDAP realm on fabricant, syncs,
  ACLs the synced group, runs a `pve-realm-sync` timer. Materialized creds from
  OpenBao by `deploy/deploy-ansible.sh`.

## Bring-up order (handled by the phased deploy — no manual seeding)

The LDAP outpost token only exists once the outpost is created in Authentik
(`authentik_token.key` is provider-read-only — Authentik mints it), which happens in
the OpenTofu phase. The fleet deploy runs NixOS (**phase 2**) before OpenTofu
(**phase 3**), so on a from-scratch deploy the token isn't in OpenBao yet when
krg-prod's `krg.vaultAgent` renders. The DAG fix handles this WITHOUT manual
seeding:

1. **Phase 2** — krg-prod `nixos-rebuild`. The outpost-token render is
   **non-fail-closed** (`errorOnMissingKey = false`), so the (empty) env file renders
   and the krg-prod stack comes up; the `authentik_ldap` container starts but can't
   connect yet (empty token — visibly offline in Admin → Outposts).
2. **Phase 3** — `terraform/authentik` apply. Creates the provider/app/outpost +
   `svc-pve-ldap` bind account, and `outpost_tokens.tf` mints the outpost API token
   and writes it to `secret/krg-prod/authentik-managed/ldap-outpost-token`.
3. **Phase 3.5** — `deploy/deploy-rerender-secrets.sh` re-runs openbao-agent on
   krg-prod: the token now renders, and the render's `reloadCommand` restarts
   `authentik_ldap` so it connects. The whole thing converges in **one** deploy run.
4. **Phase 4 / Ansible** — validate (below), then `deploy/deploy-ansible.sh` for the
   PVE realm.

Steady state (every deploy after the first) is unremarkable: the token is already in
OpenBao, so phase 2 renders it immediately and phase 3.5 is a no-op.

## ⚠ Bring-up — values that can only be confirmed against the running outpost

The exact tree/attributes Authentik's LDAP outpost serves, the bind/search
permission, and the synced PVE group id are assumptions until validated. Do this
**before** trusting the realm:

1. Apply `terraform/authentik` (mints the outpost + its token →
   `secret/krg-prod/authentik-managed/ldap-outpost-token`), then re-render krg-prod
   (`deploy/deploy-rerender-secrets.sh`, or the deploy's phase 3.5) so the token
   lands and `authentik_ldap` restarts. Confirm it connects (Admin → Outposts shows
   it healthy). No manual token seeding.
3. **`ldapsearch` against the outpost** (from fabricant) with the bind account to
   learn the real tree:
   ```bash
   ldapsearch -H ldaps://krg-prod.ucsd.edu:6636 -o tls_reqcert=never \
     -D "cn=svc-pve-ldap,ou=users,DC=krg,DC=ucsd,DC=edu" \
     -w "$(bao kv get -field=password secret/krg-prod/authentik-managed/proxmox-ldap-bind)" \
     -b "DC=krg,DC=ucsd,DC=edu" "(cn=proxmox-admins)"
   ```
   - Confirm the **base_dn**, the **group DN** (`ou=groups,…`), the **username
     attribute** (`cn` vs `uid`), and that `proxmox-admins` lists the 6 members.
   - Adjust `pve_ldap_user_attr` / `pve_ldap_*_filter` / `pve_ldap_group_dn` in the
     role to match, if needed.
   - If the bind itself fails with **`ldap_bind: Insufficient access (50)`** (authenticated
     — else it'd be `49` — but not authorized): the principal lacks **access to the LDAP
     application**. Since Authentik 2025.4 the outpost authorizes binds against the
     application's **policy bindings**, and superuser / `search_full_directory` is NOT
     sufficient on its own (goauthentik/authentik#14518). `proxmox_ldap.tf` binds BOTH
     `svc-pve-ldap` (search) and the `proxmox-admins` group (logins) to the app with
     `policy_engine_mode = "any"`. If a *user* can't log in but `svc-pve-ldap` works,
     confirm they're in `proxmox-admins` (which is bound to the app).
   - If the search *binds* but returns *nothing*, the bind account can't SEARCH the tree —
     confirm `svc-pve-ldap` is in the **`authentik Admins`** group (Admin → Directory →
     Users → svc-pve-ldap → Groups; toggle "Hide service-accounts" OFF to see it). It's
     put there by `proxmox_ldap.tf` because the scoped `search_full_directory` permission
     can't be assigned via IaC on our version (goauthentik/authentik#18562 — the RBAC
     permission-assign API 405s even for admin). Narrow back to the scoped permission once
     that's fixed. (App access governs whether you can BIND; superuser governs search
     BREADTH — both are required.)
4. **Firewall — TWO independent layers, don't conflate them:**
   - **Proxmox perimeter (`<vmid>.fw`, REQUIRED for login).** krg-prod's per-guest
     firewall (`ansible/roles/proxmox_firewall/files/krg-prod.fw`, VMID 103) is
     default-deny and must explicitly **ACCEPT 6636 from fabricant** — without it the
     VM drops PVE's bind and login fails with "can't contact LDAP server" surfaced as
     a generic **401** (this bit us: the outpost was healthy but unreachable). The
     rule is `IN ACCEPT -p tcp -dport 6636 -source 137.110.161.98`.
   - **In-guest Docker bypass (still open, hardening).** Docker publishes 6636 on all
     interfaces and DNATs past the in-guest nftables INPUT (FORWARD path), so the port
     is world-reachable on `krg-prod:6636` regardless of the perimeter rule above.
     Restrict it to fabricant with a `DOCKER-USER`/nftables FORWARD rule on krg-prod —
     same open item as dcgm 9400 (CLAUDE.md "Docker published-port firewall bypass").
     The perimeter rule is the access control today; this closes the bypass.

## Apply

1. `terraform/authentik` apply → provider/app/outpost/service-account + bind secret +
   the outpost token (`outpost_tokens.tf`).
2. `deploy/deploy-rerender-secrets.sh` (or phase 3.5) → token renders, `authentik_ldap`
   restarts and connects.
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
