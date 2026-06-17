# Hooking the lab PKI into Active Directory

Wires the OpenBao lab-internal CA (`terraform/openbao/pki.tf`) into `KRG.LOCAL` so
that **AD group membership authorizes certificate issuance**, issued certs carry
**AD identity**, and the **CA is trusted fleet-wide**. Three layers:

| Layer | Where | What |
|-------|-------|------|
| **A** Authorization | `terraform/openbao/ldap.tf` | `ldap` auth → AD groups map to `pki_int/issue/*` |
| **B** Identity | `terraform/openbao/pki.tf` (`host`, `user` roles) | `user` certs carry the AD UPN in an `otherName` SAN |
| **C** Trust | `nix/profiles/base.nix` (`security.pki`) | every host trusts the CA root → chain validation |

Machines keep authenticating with **AppRole** (a host isn't an AD user); only
**humans** use the `ldap` path, to mint their own short-lived `user` client certs.

---

## Offline / manual prerequisites (not IaC)

These can't flow through tofu/nix — they're AD objects and one-time material the
config consumes. Do them first, in order.

### 1. Dedicated AD bind account for OpenBao

Create a **read-only** service account in `KRG.LOCAL` (not a Domain Admin) that
OpenBao binds as to search users/groups. This ties into the still-incomplete AD
principal/group work (CLAUDE.md; memory `krg-local-ad-principals-pending`).

- Suggested DN: `CN=svc-openbao,CN=Users,DC=krg,DC=local`
- Give it a strong password; it needs only directory read.
- **Do not** put the password in a tfvars file or commit it. At apply time the
  operator exports it as `TF_VAR_ldap_bindpass` in their own shell.

### 2. Issuing groups exist in AD

`var.pki_ad_group_roles` defaults to `Domain Admins` (already exists). For any
other mapped group (e.g. `ARM-PDK`), create it in AD first, or the
`vault_ldap_auth_backend_group` binding maps to nothing.

### 3. Grab the DC's LDAPS CA cert (bootstrap trust)

OpenBao verifies the DC over LDAPS using `var.ldap_ca_cert`. Until the DC cert is
re-issued from `pki_int` (step 7), that's Samba's own self-signed LDAPS cert.

Discovery probe — confirms 636 is reachable **and** captures the cert:

```bash
openssl s_client -connect krg-ldap.krg.local:636 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform pem > /tmp/krg-ldap-ldaps-ca.pem
```

Export it for the apply (string var, not a file path):

```bash
export TF_VAR_ldap_ca_cert="$(cat /tmp/krg-ldap-ldaps-ca.pem)"
```

### 4. Export the CA root for fleet trust (layer C)

`nix/profiles/base.nix` trusts `nix/keys/krg-pki-ca.pem`. Pull the **root** CA
cert (the trust anchor — leaves chain leaf → intermediate → root) from OpenBao and
commit it. It's a public trust anchor, **not** a secret.

```bash
# with VAULT_ADDR + a token that can read the (public) CA endpoint
bao read -field=certificate pki/cert/ca > nix/keys/krg-pki-ca.pem
git add nix/keys/krg-pki-ca.pem
```

Until this file is committed, the `security.pki` line is a guarded no-op, so the
flake still evaluates.

---

## Apply order

```bash
# A + B — OpenBao structure (ldap auth, host/user roles, AD-group policies)
cd terraform/openbao
export VAULT_TOKEN="<root or admin token>"
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export TF_VAR_ldap_binddn="CN=svc-openbao,CN=Users,DC=krg,DC=local"
export TF_VAR_ldap_bindpass='…'                 # from your password store, your shell only
export TF_VAR_ldap_ca_cert="$(cat /tmp/krg-ldap-ldaps-ca.pem)"
tofu init && tofu plan && tofu apply

# C — fleet CA trust: commit nix/keys/krg-pki-ca.pem, push to main.
# Hosts pick it up on the next nixos-rebuild / 04:00 auto-upgrade.
```

---

## Validation

```bash
# A: a Domain Admin logs in via AD and inherits the generated policy
bao login -method=ldap username=<aduser>
bao token capabilities "$(bao print token)" pki_int/issue/user   # → create, update

# B: mint a user client cert carrying the AD UPN, confirm the SAN
bao write -format=json pki_int/issue/user common_name=<aduser> \
  other_sans="1.3.6.1.4.1.311.20.2.3;UTF8:<aduser>@krg.local" ttl=1h \
  | jq -r .data.certificate | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'

# C: on any host after rebuild, a pki_int leaf verifies against the system trust store
openssl verify <(echo "$LEAF_PEM")     # no -CAfile needed once the root is trusted
```

## Human cert issuance (who `pki_ad_group_roles` is for)

Two actors issue certs, and they're authorized differently:

| Actor | Auth to OpenBao | Authorized by | Example |
|-------|-----------------|---------------|---------|
| **Machine** | AppRole (`role_id`+`secret_id` on the host) | the role's policy (`main.tf`) | krg-prod issues `temporal-frontend`; waiter issues `host`; a long-running worker issues `temporal-client` via vault-agent |
| **Human** | `bao login -method=ldap` (their KRG.LOCAL account) | **`pki_ad_group_roles`** (`ldap.tf`) | a developer mints a client cert to reach the Temporal frontend from their laptop |

`pki_ad_group_roles` exists for the **human** row: it's how a person is allowed to
mint a cert by hand without being handed a machine's AppRole `secret_id`, governed
by the same AD groups as logins/Grafana/RDP. Nothing else reads these groups.

### Worked example — a Temporal user mints a client cert

Temporal's gRPC frontend requires a CA-signed **client** cert
(`TEMPORAL_TLS_REQUIRE_CLIENT_AUTH`). A researcher connecting interactively (the
`tctl`/`temporal` CLI or an SDK from their workstation) needs one. They're in the
`Temporal Users` AD group, mapped to the `user` role, so:

```bash
# 1. authenticate with the AD account (no AppRole secret handed out)
bao login -method=ldap username=alice

# 2. mint a short-lived client cert carrying alice's AD UPN (her identity travels
#    in the cert, so Temporal authz can key off it)
bao write -format=json pki_int/issue/user \
  common_name=alice \
  other_sans="1.3.6.1.4.1.311.20.2.3;UTF8:alice@krg.local" \
  ttl=8h > /tmp/cert.json
jq -r .data.certificate  /tmp/cert.json > ~/.temporal/client.pem
jq -r .data.private_key  /tmp/cert.json > ~/.temporal/client.key

# 3. point the client at it (the CA root is already in the system trust store, layer C)
temporal --tls-cert-path ~/.temporal/client.pem \
         --tls-key-path  ~/.temporal/client.key \
         --address workflows.krg.ucsd.edu:7233  workflow list
```

**Why `user` and not `temporal-client` for humans:** `temporal-client`'s
`allowed_domains` are scoped to service names (`temporal-worker`, `temporal-ui`,
the tofu runner) for *machine* callers; a person's cert instead carries their AD
UPN via the `user` role, so the identity is auditable and reusable for any
future mTLS service. The frontend accepts either (it only checks CA-signing).
The short TTL (≤7d) is fine for interactive use — re-mint at the start of a
session; long-running workers stay on the machine/AppRole path instead.

> **Prerequisite:** the `Temporal Users` group (and any other mapped group) must
> exist in `KRG.LOCAL`. Until then the binding matches no one — see
> `var.pki_ad_group_roles` and `krg-local-ad-principals-pending`.

## Closing the bootstrap loop (optional, after the chain is up)

7. Re-issue the DC's LDAPS cert from `pki_int` (role `host`, SAN
   `krg-ldap.krg.local`), install it on the Samba DC, then swap `TF_VAR_ldap_ca_cert`
   to the lab root and re-apply. Now the whole LDAPS path chains to the lab CA
   instead of a one-off self-signed cert.

## Beyond this scope

The `user` cert SANs are deliberately **PKINIT-ready** (UPN `otherName`). Full
cert-based Kerberos logon — making `krg-ldap`'s KDC trust the CA — is a separate,
larger effort and is **not** wired here.
