# Joining a host to the domain (KRG.LOCAL)

Every managed host is an Active Directory **client** of the `KRG.LOCAL` Samba
forest on **krg-ldap**, so people log in with their AD accounts (only the local
break-glass `krg-admin` stays off AD). Deploying the AD-client config is automated;
the **one-time domain join** — getting the host a Kerberos **keytab**
(`/etc/krb5.keytab`) so it can prove its machine identity — is a stateful manual
step that cannot live in code. This runbook is that step.

There are **three cases**, and they differ:

| Host kind | Module | How it gets its keytab |
|---|---|---|
| **NixOS member** (waiter, krg-prod, e4e-prod) | `krg.adClient` ([`sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)) | `adcli join` on the box |
| **Debian/PVE host** (fabricant) | Ansible `ad_client` role | `-e ad_join_password=…` on the play |
| **The DC itself** (krg-ldap) | `krg.adClient.isDomainController = true` | `samba-tool domain exportkeytab` (no join) |

> **Prerequisites:** krg-ldap is provisioned and `samba-ad-dc` is running (see
> [krg-ldap-topology.md](krg-ldap-topology.md) and the provisioning notes in
> [`samba-ad.nix`](../nix/modules/samba-ad.nix)). You need **Domain Admin**
> credentials (the `Administrator` password set at provision time). SSH stays
> key-only throughout — the join password is for Kerberos, never for SSH.

> Creating the *users* who then log in is a separate runbook:
> [creating-a-user.md](creating-a-user.md).

---

## Why a join is needed (and what already works without it)

Deploying the AD-client config alone is **safe and non-breaking**: SSSD just runs
offline, and local `krg-admin` key login keeps working. What *doesn't* work until
the join is done: AD users resolving/logging in on that host, because SSSD has no
keytab to authenticate the machine to the DC. So the order is always **deploy the
config first, join second, validate third.**

A useful tell that a host is *deployed but not joined*: a brand-new (uncached) AD
user gets a bare `Permission denied (publickey)`. (If even cached users fail, see
the DNS-flap entry in [troubleshooting.md](troubleshooting.md) first — an
unresolvable `krg.local` looks the same.)

---

## Case 1 — NixOS member host (waiter, krg-prod, e4e-prod, krg-vault, krg-deploy)

The config is already in the `base` profile (`krg.adClient`, pinned to the DC at
137.110.161.109). After the host is deployed:

**1. Confirm the DC is reachable and resolvable from the host.**
```bash
getent hosts krg-ldap.krg.local        # should return 137.110.161.109 (pinned in /etc/hosts)
host -t SRV _ldap._tcp.krg.local       # should list the DC (needs DC as primary DNS)
```
If the SRV lookup fails, the host can't reach `krg.local` DNS — fix that before
joining (the module sets the DC as primary resolver; see the DNS-flap entry in
[troubleshooting.md](troubleshooting.md)).

**2. Get a Kerberos ticket as a Domain Admin, then join.**
```bash
kinit Administrator@KRG.LOCAL          # prompts for the Domain Admin password
adcli join --domain krg.local \
  --domain-controller krg-ldap.krg.local \
  --login-ccache \
  --host-fqdn "$(hostname).krg.local"
```
> This is the procedure that joined **waiter** (2026-05-21): `kinit` for a ticket,
> then `adcli join --login-ccache` so the join reuses that ticket instead of
> re-prompting. `adcli` writes the machine account to AD and drops the keytab at
> `/etc/krb5.keytab`.

**3. Make the keytab survive (impermanent hosts only — e.g. waiter).**
`/etc/krb5.keytab` is already in the `/persist` file list
([`impermanence.nix`](../nix/modules/impermanence.nix)), so the bind mount captures
it — but confirm the persisted copy is non-empty after the join (the path is
pre-seeded empty before the join lands):
```bash
test -s /persist/etc/krb5.keytab && echo "keytab persisted" || \
  echo "WARNING: persisted keytab is empty — the next reboot will drop the join"
```

**4. Bring SSSD online and validate.**
```bash
sudo systemctl restart sssd
id 'someuser'                          # AD user resolves (uid/gid SID-mapped)
getent passwd someuser
adcli testjoin                         # "Successfully validated join"
```

---

## Case 2 — Debian / Proxmox host (fabricant)

The Ansible `ad_client` role ([`tasks/main.yml`](../ansible/roles/ad_client/tasks/main.yml))
does the join for you when you pass the password at runtime. It is **idempotent**:
`adcli testjoin` gates the join, so re-runs without the password are no-ops on an
already-joined host (the play still stages config + warns if *not* joined).

**Run the baseline with the join password (one time):**
```bash
cd ansible
ansible-playbook playbooks/site.yml -e ad_join_password='<Domain Admin password>'
```
- The password is `no_log` and **never stored** — only used for that `adcli join`.
- Join user defaults to `Administrator`, DC to `krg-ldap.krg.local` (137.110.161.109,
  pinned in `/etc/hosts` by the role — so a hypervisor never depends on a guest it
  hosts for DNS). Override via `ad_join_user` / `ad_dc_*` in
  [`ad_client/defaults/main.yml`](../ansible/roles/ad_client/defaults/main.yml).
- Without the password on an unjoined host, the play **stages config and warns**
  rather than failing — the baseline stays runnable everywhere.

**Validate on the host:**
```bash
adcli testjoin
id 'someuser'; getent passwd someuser
systemctl status sssd
```

> **Bootstrap caveat (fabricant):** fabricant is an AD client of `krg-ldap`, which
> runs as a VM **on fabricant**. If fabricant is down, so is the DC — the local
> break-glass `krg-admin` (key-only, off AD) is the deliberate escape hatch. Don't
> remove it.

---

## Case 3 — the domain controller itself (krg-ldap)

krg-ldap does **not** join — it *is* the domain. `krg.adClient.isDomainController
= true` ([`directory.nix`](../nix/profiles/directory.nix)) tells SSSD not to rotate
the DC's own machine account or push DNS, and yields `krb5.conf` to the samba-ad
module. The DC gets its keytab by **exporting** it from the directory:

```bash
# on krg-ldap, as root, after `samba-tool domain provision`:
sudo samba-tool domain exportkeytab /etc/krb5.keytab
sudo systemctl restart sssd
kinit administrator@KRG.LOCAL && klist     # sanity check
```

---

## Access control (who can log in / sudo, after the join)

The join makes AD identities *resolvable*; **access** is a separate gate, set per
host in the flake / inventory:

- **Login** — `krg.adClient.allowedGroups` (nix) / `ad_allowed_groups` (ansible),
  an `ad_access_filter` on `memberOf`. Default fleet-wide: **`Domain Admins`**.
  waiter widens to `[ "Domain Admins" "Waiter" ]`; Proxmox hosts stay admins-only.
- **Sudo (password required)** — `sudoGroups` / `ad_sudo_groups`, default
  `Domain Admins`. (Break-glass `krg-admin` keeps its own NOPASSWD rule.)
- **SSH keys** are served *from AD* (`sshKeysFromAD` / `ad_ssh_keys_from_ad`),
  which needs the one-time OpenSSH-LPK schema extension — see the appendix in
  [creating-a-user.md](creating-a-user.md).

Widening a compute host to a lab group (e.g. waiter's `Waiter` group) requires that
group to exist in AD with members — also covered in
[creating-a-user.md](creating-a-user.md).

---

## Status (2026-05-23)

| Host | Joined? |
|---|---|
| krg-ldap | ✅ provisioned + keytab exported (the DC) |
| waiter | ✅ joined 2026-05-21 (`adcli --login-ccache`) |
| fabricant | ⏳ pending (`-e ad_join_password=…`) + on-box validation |
| krg-prod / e4e-prod | ⏳ pending (not yet deployed) |
| krg-vault / krg-deploy | ⏳ pending — `krg.adClient.enable = false` until a keytab is provisioned |
