# Creating a User (KRG Active Directory)

KRG human accounts live in the **KRG.LOCAL** Samba AD forest, hosted on the
domain controller **krg-ldap**. This runbook covers creating an account and
making it able to log into AD-integrated hosts over SSH.

> Local break-glass admins (`krg-admin`/`e4e-admin`) are a *separate*, host-local
> mechanism defined in `nix/users/admin.nix` — not AD accounts. Keep at least one
> working so you can never be locked out by an AD outage.

All `samba-tool`/`ldbmodify` commands run **on krg-ldap as root** (they edit the
directory database directly). SSH stays **key-only** everywhere (no passwords on
the wire); the password you set below is only used for Kerberos (`kinit`), `sudo`,
console, etc.

## Prerequisites (one-time, already in place)

- The domain controller is provisioned and `samba-ad-dc` is running.
- The target host runs the SSSD AD client (`krg.adClient` — see
  [`nix/modules/sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)), with its
  keytab exported (`samba-tool domain exportkeytab /etc/krb5.keytab`). krg-ldap
  itself qualifies; member hosts get this as the SSSD rollout proceeds.
- For SSH keys served from AD: the OpenSSH-LPK **schema extension** has been
  applied once to the forest — see [Appendix: schema extension](#appendix-one-time-schema-extension).

## Steps

### 1. Create the account

```bash
sudo samba-tool user create <username>
# optionally: --given-name="..." --surname="..." --mail-address="...@ucsd.edu"
```

You're prompted for a password. Use a strong one — the domain enforces complexity
and the rebuild this directory replaced was driven by a *dictionary* attack. Do
**not** reuse any old-domain password; old hashes are considered compromised and
are never imported.

### 2. POSIX identity — automatic

Nothing to do here. The SSSD client uses **algorithmic ID mapping**
(`krg.adClient.idMapping = true`, the default): each user's uid/gid is derived from
their AD SID — deterministic and identical on every SSSD host — and the home
directory and login shell come from the client config (`/home/<username>`, and a
Nix-store `bash` — *not* `/bin/bash`, which doesn't exist on NixOS). You never
assign `uidNumber`/`gidNumber` per user.

> Only on a host configured with `idMapping = false` (RFC2307 mode) must each
> account carry `uidNumber`, `gidNumber`, `unixHomeDirectory` and `loginShell`
> explicitly — set via `samba-tool user edit <username>`, with a matching
> `gidNumber` on the primary group (`samba-tool group edit "Domain Users"`).

### 3. Grant access to the right hosts

Login is gated per host by `krg.adClient.allowedGroups` (an SSSD `ad_access_filter`
on group membership). Add the user to the group that host allows:

```bash
sudo samba-tool group addmembers "Domain Admins" <username>   # e.g. for the DC
```

krg-ldap (the directory server) only admits **Domain Admins**. Member hosts will
admit whatever group their config names (e.g. a lab-users group) — not the DC.

### 4. Add the user's SSH public key to AD

Requires the [schema extension](#appendix-one-time-schema-extension). The auxiliary
class must be **committed before** the attribute it permits, so this is two
separate modifies — one to attach `ldapPublicKey`, one to set the key:

```bash
USER='<username>'
KEY='ssh-ed25519 AAAA...your-public-key... you@laptop'   # ed25519 only (RSA is rejected)
DN=$(sudo samba-tool user show "$USER" | sed -n 's/^dn: //p' | head -1)

# a. attach the aux class
sudo ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF
dn: $DN
changetype: modify
add: objectClass
objectClass: ldapPublicKey
-
EOF

# b. now sshPublicKey is permitted on the object
sudo ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF
dn: $DN
changetype: modify
add: sshPublicKey
sshPublicKey: $KEY
-
EOF
```

To **rotate** a key later, repeat step (b) with `replace: sshPublicKey` instead of
`add:`. (`$USER` is also a built-in shell variable defaulting to your current
login — make sure it holds the AD username, or just use the literal name.)

### 5. Refresh the cache and verify

```bash
sudo sss_cache -E                              # drop stale negative cache entries
getent passwd <username>                       # ...:10001:10000:...:/home/<username>:<shell> (store bash on NixOS; /bin/bash on Debian)
id <username>                                  # groups include the access group
sss_ssh_authorizedkeys <username>              # echoes the key back
```

### 6. Log in

```bash
ssh <username>@<host>          # e.g. krg-ldap.ucsd.edu / 137.110.161.109
```

No directories are pre-created: the key comes from AD, and `pam_mkhomedir` creates
`/home/<username>` on first login.

## Granting GPU (CUDA) access on compute hosts

GPU access is **separate from login**. On compute hosts (e.g. waiter) the NVIDIA
device nodes `/dev/nvidia*` are owned `root:cuda` mode `0770`, so using CUDA needs
membership in the local `cuda` group — *not* the group that lets the user SSH in
(`krg.adClient.allowedGroups`, e.g. `Waiter`). SSSD algorithmic ID mapping derives an
AD group's gid from its SID, so an AD group can't directly own the fixed device gid;
instead the **`GPU Users`** AD group is bridged into the local `cuda` group by the
`cuda-group-sync` unit (`krg.nvidia.cudaAccessGroups`, see
[`nix/modules/hardware/nvidia.nix`](../nix/modules/hardware/nvidia.nix)).

To give a user the GPU, add them to `GPU Users` (create it once if it doesn't exist):

```bash
# On krg-ldap, as root.
sudo samba-tool group add "GPU Users"          # one-time, if not already present
sudo samba-tool group addmembers "GPU Users" <username>
```

The compute host re-syncs membership on boot and every 10 min; to apply it now:

```bash
# On the compute host (e.g. waiter), as root.
sudo systemctl start cuda-group-sync
getent group cuda          # now lists <username>
```

The user must **log in again** afterwards — supplementary groups are read at login
(`initgroups`), so an existing session won't pick up `cuda` until the next login.
Verify with `id | grep cuda` then `nvidia-smi`. Removing a user from `GPU Users`
revokes their GPU access on the next sync.

## Giving a user a non-default login shell (e.g. zsh)

`chsh` does **not** work for AD accounts: they aren't in `/etc/passwd` (NSS resolves
them through `sss`), and SSSD doesn't implement shell changes — the login shell is
owned by the **directory**, not the local box. Without a `loginShell` attribute every
account gets the host's configured SSSD `default_shell` (a Nix-store `bash` on NixOS
members, `/bin/bash` on Debian/PVE members). To give one user a different shell, set
`loginShell` on their AD object — it is read on every member host.

```bash
# On krg-ldap, as root. (loginShell is just the shell; it does NOT turn on RFC2307
# mode, so in the default id-mapping mode uid/gid stay algorithmic — don't add
# uidNumber/gidNumber.)
sudo samba-tool user edit <username>
# add a line:
loginShell: /run/current-system/sw/bin/zsh
```

**Use the path that exists on the host where the user does interactive work**, because
`loginShell` is a single value read fleet-wide and the path differs per platform:

| Host kind | zsh path to use |
|---|---|
| NixOS with `programs.zsh.enable` (e.g. waiter) | `/run/current-system/sw/bin/zsh` |
| Debian/PVE member (`apt install zsh`) | `/usr/bin/zsh` |

The SSSD config sets `allowed_shells = *` + `shell_fallback` (the Nix-store bash on
NixOS, `/bin/bash` on Debian — see [`nix/modules/sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)
and [`ansible/roles/ad_client`](../ansible/roles/ad_client/)), so the value is
**fail-safe**: a shell is used only on hosts where that exact path is in `/etc/shells`,
and on hosts that lack it the user **falls back to bash instead of being locked out**.
So a NixOS zsh path gives zsh on waiter and bash on the hypervisor/DC — no lockout, but
also no zsh there. A single `loginShell` can encode only one path; if a user needs zsh
on *both* a NixOS host and a Debian host (whose paths differ), set the value for their
primary host and add a guarded `exec zsh` to `~/.bash_profile` on the other:

```sh
if [[ $- == *i* ]] && command -v zsh >/dev/null 2>&1; then exec zsh -l; fi
```

Then refresh and verify (the user re-logs in to pick it up):

```bash
sudo sss_cache -E                  # on each affected member host (or wait for cache expiry)
getent passwd <username>           # last field shows the chosen shell where installed
```

> The local break-glass admin (`krg-admin`/`e4e-admin`) is a files-NSS user, not SSSD,
> so none of this touches it — its shell stays whatever `nix/users/admin.nix` sets.

## Enabling self-service password reset (Authentik recovery flow)

Authentik's "Forgot password?" flow (`terraform/authentik/recovery.tf`) lets a
user reset their **actual AD password** via an emailed link — the LDAP source's
`sync_users_password = true` (`terraform/authentik/ldap.tf`) writes the new
password back to AD when the flow completes. This requires a **one-time AD-side
delegation**, run once per forest (not per-user): without it, AD correctly
refuses the writeback and the user sees "Failed to update user. Please try
again later." on the reset page, with the real reason
(`insufficient access rights ... insufficientAccessRights`) logged by
`authentik_server`.

AD models "reset someone else's password without knowing their current one" as
a separate, privileged operation from an ordinary password *change* — gated
behind the **User-Force-Change-Password** extended right (display name "Reset
Password", GUID `00299570-246d-11d0-a768-00aa006e0529`, per
[Microsoft's AD schema reference](https://learn.microsoft.com/en-us/windows/win32/adschema/r-user-force-change-password)).
This is exactly the operation Authentik needs: the user proved their identity
via the emailed token, not by typing their existing AD password.

Grant it to the `authentik-bind` service account (`CN=authentik-bind,CN=Users,DC=KRG,DC=LOCAL`,
the bind account `terraform/authentik/ldap.tf` uses) on the `Users` container,
**on krg-ldap as root**:

```bash
# 1. Resolve authentik-bind's SID (samba-tool prints objectSid as a string)
SID=$(sudo samba-tool user show authentik-bind | sed -n 's/^objectSid: //p')
echo "$SID"   # sanity check — should look like S-1-5-21-...

# 2. Grant Reset Password, inheritable to every user object under the container
#    (CI = Container Inherit — without it the ACE sits on the container itself,
#    which has no password, and grants nothing useful).
sudo samba-tool dsacl set \
  --objectdn="CN=Users,DC=KRG,DC=LOCAL" \
  --sddl="(OA;CI;CR;00299570-246d-11d0-a768-00aa006e0529;;$SID)"

# 3. Verify the ACE landed
sudo samba-tool dsacl get --objectdn="CN=Users,DC=KRG,DC=LOCAL" | grep -A1 "$SID"
```

The SDDL ACE `(OA;CI;CR;<guid>;;<SID>)` breaks down as: **O**bject-specific
**A**llow ACE, **C**ontainer-**I**nherit (propagates to every child object, not
just the container itself), **C**ontrol-**R**ight (an extended right, not an
ordinary attribute read/write), scoped to the named GUID (which right), granted
to the trustee SID (which account). `samba-tool dsacl set --car=...` can't
express this — its `--car` flag only covers a fixed set of DS-replication
rights (change-rid, get-changes, etc.), not User-Force-Change-Password, so the
raw `--sddl` form is required here.

**Scope note:** since `samba-tool user create` (step 1 above) doesn't specify
an OU, all human accounts *and* service accounts like `authentik-bind` itself
share the flat `CN=Users` container — there's no OU split between them yet. So
this grants `authentik-bind` reset rights over every object in that container,
including other service accounts placed there later (e.g. `svc_roster` from
`terraform/authentik/roster_secrets.tf`), not just human users. Narrowing this
would require moving service accounts into their own OU — out of scope here.

**Verify it actually works** (tests AD itself, not just that Authentik accepted
the new password into its own internal store):

```bash
kinit <username>@KRG.LOCAL        # realm is case-sensitive — must be UPPERCASE
# enter the NEW password — success means AD genuinely has it
```

## Appendix: one-time schema extension

AD ships no SSH-key attribute, so the OpenSSH-LPK schema must be added **once** to
the forest. This is **forest-wide and permanent** — an attribute can't be cleanly
removed from an AD schema afterwards. The attribute must exist and the schema must
reload *before* the class that references it, so it's stepwise:

```bash
# 1. the sshPublicKey attribute
sudo ldbadd -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn: CN=sshPublicKey,CN=Schema,CN=Configuration,DC=krg,DC=local
objectClass: top
objectClass: attributeSchema
cn: sshPublicKey
attributeID: 1.3.6.1.4.1.24552.500.1.1.1.13
lDAPDisplayName: sshPublicKey
attributeSyntax: 2.5.5.10
oMSyntax: 4
isSingleValued: FALSE
EOF

# 2. reload so the attribute is known
sudo ldbmodify -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn:
changetype: modify
replace: schemaUpdateNow
schemaUpdateNow: 1
EOF

# 3. the ldapPublicKey auxiliary class (objectClassCategory 3) that permits it
sudo ldbadd -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn: CN=ldapPublicKey,CN=Schema,CN=Configuration,DC=krg,DC=local
objectClass: top
objectClass: classSchema
cn: ldapPublicKey
governsID: 1.3.6.1.4.1.24552.500.1.1.2.0
lDAPDisplayName: ldapPublicKey
subClassOf: top
objectClassCategory: 3
mayContain: sshPublicKey
EOF

# 4. reload again, then restart so it's fully live
sudo ldbmodify -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn:
changetype: modify
replace: schemaUpdateNow
schemaUpdateNow: 1
EOF
sudo systemctl restart samba-ad-dc
```

## Troubleshooting

- **`attribute 'sshPublicKey' ... was not found in the schema`** — the schema
  extension hasn't run; do the appendix first.
- **`attribute 'sshPublicKey' ... does not exist in the specified objectclasses`**
  — you tried to add the class and the key in one modify; split into 4a then 4b.
- **`sss_ssh_authorizedkeys` → "Error looking up public keys"** — the host isn't
  running the `sshKeysFromAD` config yet (no SSSD `ssh` responder). Deploy it
  (`git pull && sudo nixos-rebuild switch --flake ./nix#<host>`) and check the
  `services =` line in `/etc/sssd/sssd.conf` includes `ssh`.
- **`ssh` fails with "Permission denied (publickey)" but the key is confirmed
  correct** — check the sshd log (`sudo journalctl -u sshd -b | tail`). On NixOS,
  a login shell of `/bin/bash` doesn't exist, so sshd rejects the account *pre-auth*
  as an "invalid user" ("shell /bin/bash does not exist"), which masquerades as a
  publickey denial. The module sets a valid store-path shell; if you hit this, the
  host isn't on the fixed config — `git pull && nixos-rebuild switch`.
- **`getent passwd <username>` empty** — in the default id-mapping mode, usually a
  stale cache (`sudo sss_cache -E`) or the SSSD domain being offline
  (`sudo sssctl domain-status KRG.LOCAL`). In RFC2307 mode (`idMapping = false`),
  it means the POSIX attrs are missing or the user's `gidNumber` doesn't match a
  group that has that `gidNumber`.
- **Authentik password reset shows "Failed to update user. Please try again
  later."**, and `authentik_server` logs `insufficient access rights ...
  insufficientAccessRights` from `authentik_sources_ldap` — the one-time AD
  delegation hasn't been granted yet; see
  [Enabling self-service password reset](#enabling-self-service-password-reset-authentik-recovery-flow).
- **`kinit user@KRG.local` → "KDC reply did not match expectations"** — the
  realm is lowercase; Kerberos realms are case-sensitive and this forest is
  `KRG.LOCAL` (uppercase). Not a password problem.
