# Mounting E4E NAS shares (`e4e-nas-mount`)

On **kastner-ml**, members of the **`E4E-NAS`** AD group can mount E4E NAS
(`e4e-nas.ucsd.edu`) CIFS/SMB shares into their home directory **without full
sudo**, using a small validated wrapper. You authenticate as *yourself* with your
Kerberos ticket — there is **no password or credentials file stored on disk**.

> **TL;DR**
> ```bash
> sudo e4e-nas-mount passive-acoustic-biodiversity tests
> # first time in a session it prompts for your AD password (kinit); after that,
> # nothing. The share appears at ~/tests, owned by you.
>
> sudo e4e-nas-mount -u tests          # unmount when you're done
> ```

This is wired by the NixOS module [`nix/modules/nas-mount.nix`](../nix/modules/nas-mount.nix)
(`krg.nasMount`), enabled on kastner-ml. It replaces the old "give people raw
`sudo mount`" approach, which couldn't stop a user mounting a share over `/etc`
or passing hostile mount options.

---

## For users

### Prerequisites (one-time)

- You can **SSH into kastner-ml** with your AD account. (Login is gated by
  `krg.adClient.allowedGroups` — E4E users already have this via the `kastnerml`
  group.)
- You are a member of the **`E4E-NAS`** AD group. If `sudo e4e-nas-mount …` says
  *"a password is required"* or *"user is not allowed to run sudo"*, you're not in
  the group yet — ask an admin (see [Granting access](#for-operators-granting-access)).
- The share you're mounting grants your AD identity access in its **SMB
  permissions on the NAS itself** (managed in `spec/e4e-nas/`, DSM-side). The
  wrapper only lets you *run* the mount — the NAS still enforces who can read the
  share.

### Mount a share

```bash
sudo e4e-nas-mount <share> [mountpoint]
```

- `<share>` — the share name on `//e4e-nas.ucsd.edu/`, e.g.
  `passive-acoustic-biodiversity`. Bare name only (no slashes).
- `[mountpoint]` — where to mount it, **relative to your home** (or an absolute
  path that resolves under your home). Defaults to `~/<share>` if omitted.

Example — mount `passive-acoustic-biodiversity` at `~/tests`:

```bash
sudo e4e-nas-mount passive-acoustic-biodiversity tests
```

What happens:

1. **No sudo password** is asked (the wrapper is `NOPASSWD` for `E4E-NAS`).
2. If you have **no valid Kerberos ticket**, the wrapper runs `kinit` *as you* and
   prompts for your **AD password** — once. If you already have a ticket (e.g. you
   ran `kinit` earlier, or mounted something already this session), it's reused
   silently, no prompt.
3. The share is mounted at `~/tests`, and every file in it is **owned by you**
   (your uid/gid). Only you can read it (`file_mode=0700`).

You can mount several shares; each gets its own mountpoint under your home.

### Unmount

```bash
sudo e4e-nas-mount -u tests          # or the absolute path you mounted at
```

Mounts are not automatically restored across reboots — re-run `e4e-nas-mount`
after a reboot or a fresh login if you need the share again.

### Do I have to keep re-entering my password?

**No.** After the first `kinit` of a session, a background per-user service
(`krg-krenew`) keeps your ticket renewed for the whole time you're logged in — up
to the **7-day** renewable lifetime — so a long-lived mount keeps reconnecting and
you never re-type your password. This is the same renewal mechanism described in
[Keeping long jobs authenticated](kerberos-long-jobs.md). When you fully log out,
renewal stops (the ticket cache lives in `/tmp` and expires on its own).

### Why a ticket instead of a credentials file?

The mount uses **`sec=krb5`** — Kerberos. Your identity comes from your login
ticket, so there is **no password written to a file** anywhere on the box. That's
the whole reason for the one `kinit` prompt: a key-only-SSH login never sees your
password, so Kerberos needs it once to get the ticket. The alternative — a
`credentials=~/e4e-cred` file — would leave your password sitting in plaintext in
your home directory, which we deliberately avoid.

### Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `sudo: a password is required` / `not allowed to run sudo` | You're not in the `E4E-NAS` group. Ask an admin to add you. |
| `kinit` fails / *"Preauthentication failed"* | Wrong AD password, or your account is locked. Try `kinit` on its own to confirm. |
| `mount error(13): Permission denied` | You have a ticket, but the **share's SMB permissions** on the NAS don't grant you access. This is a NAS-side ACL (`spec/e4e-nas/`), not the wrapper. |
| `mount error(126)` / `Key has expired` on a long mount | Your ticket lapsed and wasn't renewed. Re-run `kinit`; check `klist`. `krg-krenew` should keep it alive while you're logged in. |
| `refuses: mountpoint must be under your home` | The mountpoint has to resolve to a path inside your home directory. Pick a spot under `~`. |
| `refuses: invalid share name` | Share names are bare (`[A-Za-z0-9._-]`), no slashes or `..`. Pass just the share name. |

`klist` shows your current ticket; `mount | grep cifs` (or `findmnt -t cifs`) shows
what's mounted.

---

## For operators (granting access)

Access is gated on the **`E4E-NAS`** AD group in **two** places, both driven from
this repo — grant is just *adding the user to the group*:

1. **The mount wrapper** — the sudoers rule is `%E4E-NAS` (NixOS
   `krg.nasMount.allowedGroup`, [`nix/modules/nas-mount.nix`](../nix/modules/nas-mount.nix)).
2. **The Authentik "E4E NAS" and "E4E Garage UI" app tiles** — both restricted to
   the same group ([`terraform/authentik/app_access.tf`](../terraform/authentik/app_access.tf)),
   so only NAS users see them on the SSO dashboard. (Garage UI *also* gates
   admin-vs-read internally via its OIDC `groups` claim — that's a separate in-app
   role check, complementary to this tile gate.)

The group object itself is declared in
[`spec/krg-ad/groups.yml`](../spec/krg-ad/groups.yml) (`E4E-NAS`) — its name is
**space-free on purpose** so it's safe in `%E4E-NAS` sudoers and resolvable by the
Authentik lookup.

### Add a user to `E4E-NAS`

Group **membership of humans is roster-managed** (ADR 0010), so prefer the roster
flow. To add directly on the DC (**krg-ldap, as root**):

```bash
sudo samba-tool group addmembers "E4E-NAS" <username>
```

Membership propagates automatically:

- **Mount access** — SSSD refreshes group membership within its cache timeout; the
  user may need to log out/in for a fresh session. No redeploy needed.
- **Authentik tile** — appears after the next LDAP sync.

> The user must **also be able to log into kastner-ml** (`krg.adClient.allowedGroups`
> = `Domain Admins` / `kastnerml`). E4E users already are; if a new NAS user can't
> SSH in, add their login group there too and redeploy.

### First-time setup / new host

If you ever enable this on another host, add it to that host's config:

```nix
imports = [ ../../modules/nas-mount.nix ];
krg.nasMount.enable = true;   # defaults: server = e4e-nas.ucsd.edu, group = E4E-NAS
```

The host must be an AD member with the **cifs.spnego upcall wired** (the compute
profile does this — [`nix/profiles/compute.nix`](../nix/profiles/compute.nix)), or
`sec=krb5` mounts fail with `-126 / ENOKEY`.

### Applying changes (three layers)

The `E4E-NAS` group must exist in AD **and be synced into Authentik** *before* the
Authentik apply, or the `data.authentik_group` lookup fails `tofu apply`.

1. **AD group** (if not already present): `ansible krg-ad` apply — creates the
   group object (non-authoritative; it never deletes or edits membership).
2. **NixOS**: `nixos-rebuild switch --flake ./nix#kastner-ml --target-host …`.
3. **Authentik**: `tofu apply` in `terraform/authentik`.
