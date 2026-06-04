# Keeping Long Jobs Authenticated (Kerberos ticket renewal)

KRG hosts join the **KRG.LOCAL** Samba AD forest, and Kerberos tickets you get
from `kinit` last **10 hours**. A training run, batch job, or `sec=krb5` SMB mount
that outlives that window loses authentication mid-flight — you come back to a job
that died on `Permission denied` or a mount throwing `ESTALE` / `Key has expired`.

This runbook is how to keep a job authenticated for its whole run **without** a
keytab (a stored, password-equivalent credential we deliberately avoid — see
[Why not a keytab](#why-not-a-keytab)) and **without** babysitting `kinit`.

> **TL;DR**
> ```bash
> kinit                       # once; gives you a ticket renewable for 7 days
> krenew -K 60 -- ./yourjob   # wrap the job; it auto-refreshes until the job exits
> ```

## How it works

A Kerberos ticket has **two** clocks, and they're independent:

- **Ticket lifetime — 10h.** How long one ticket is valid. We keep this short on
  purpose: it's the revocation cadence. A leaked credential cache is only good for
  what's left of its 10h, and disabling an account stops renewal at the next
  boundary.
- **Renewable lifetime — 7 days.** How long you're allowed to keep asking the KDC
  for a *fresh* 10h ticket **without re-entering your password**.

`krenew` sits next to your job and, before each 10h ticket expires, renews it — a
rolling sequence of fresh 10h tickets for up to the 7-day cap. The ticket lifetime
never changes; you just never let it lapse.

`renew_lifetime = 7d` is set in the generated `krb5.conf`
([`nix/modules/sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)), so a plain
`kinit` already hands you a renewable ticket — no `-r` flag needed. `krenew`/`k5start`
ship in the `kstart` package on every AD-joined host.

## Usage

### Wrap the job (recommended)

```bash
kinit                            # enter your AD password (skip if you have a live ticket)
krenew -K 60 -- ./train.sh       # -K 60: check every 60s and renew when near expiry
```

`krenew` becomes the parent of `./train.sh`. It refreshes the ticket for the whole
run and **exits when the job exits** — no leftover daemon, no lingering session to
manage. Run it inside `tmux`/`nohup` as usual; the ticket cache (`FILE:/tmp/krb5cc_<uid>`)
survives logout, so the job keeps its credential after you disconnect.

```bash
tmux new -s train
kinit
krenew -K 60 -- ./train.sh
# Ctrl-b d to detach; log out; job + renewal keep running
```

### Kerberos SMB mounts (`sec=krb5`)

If your job reads/writes a `sec=krb5` CIFS mount (e.g. an `e4e-nas` share), the same
wrapper covers it. Steady reads/writes over an established SMB session don't re-check
Kerberos; only **reconnects** (idle timeout, network blip, server reboot) do — and
those go through the kernel's `cifs.upcall`, which reads the *same*
`FILE:/tmp/krb5cc_<uid>` cache `krenew` is refreshing. So a job under `krenew` keeps
its mount reconnecting cleanly for the full renewable window.

Two conditions to be aware of:

- **Mount as yourself.** The reconnect uses the mounting uid's cache. If *you* ran
  `mount`, that's your renewed cache — fine. If a mount is issued by root
  (fstab/systemd/autofs), add `cruid=<you>` so the upcall uses your cache, not root's.
- The `default_ccache_name = FILE:/tmp/krb5cc_%{uid}` pin in `krb5.conf` is what
  guarantees `kinit`, `krenew`, and `cifs.upcall` all agree on one cache. Don't point
  `KRB5CCNAME` at a session keyring for these jobs.

## Verifying

```bash
klist
```

- **`renew until`** ~7 days out → your ticket is renewable (good).
- **`Ticket cache: FILE:/tmp/krb5cc_<uid>`** → the persistent, per-uid cache the
  mount upcall also reads.

Watch a renewal happen:

```bash
krenew -v -K 60 -- sleep 120     # -v prints each refresh
```

## Limits & gotchas

- **7-day ceiling.** The renewable lifetime is capped at 7 days by the domain
  (`MaxRenewAge`). A job longer than a week will still need a fresh `kinit` (or, for
  genuinely unattended >7d runs, talk to infra about a scoped service account). Most
  jobs finish well inside this.
- **Renew before it lapses.** A ticket that has *fully* expired can't be renewed —
  you'd need a new `kinit`. With `-K 60`, `krenew` refreshes long before the 10h mark;
  this only bites if `krenew` is killed or the box is suspended/down for >10h
  mid-job (in which case the job was probably interrupted anyway).
- **Password change.** When your AD password expires/rotates (you'll see a warning at
  `kinit`), just `kinit` with the new one. Nothing else to re-issue — this is the
  payoff of *not* using a keytab.

## Why not a keytab

A keytab is a stored credential equivalent to your password. On these hosts it would
land on snapshotted NFS `/home`, silently break on every password rotation, and
re-introduce exactly the "one box compromise = durable identity theft" shape this
infrastructure was rebuilt to remove. Renewable tickets get you "never re-`kinit`
mid-job" with **no secret at rest** and natural expiry — strictly the better trade
for interactive and per-user jobs. Keytabs are reserved for genuinely unattended,
non-human *service* accounts, decided case by case.

## Related

- [`docs/creating-a-user.md`](creating-a-user.md) — AD account creation.
- [`docs/joining-a-host-to-the-domain.md`](joining-a-host-to-the-domain.md) — how a
  host joins KRG.LOCAL (and gets its own machine keytab, distinct from user tickets).
- [`nix/modules/sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix) — the SSSD/krb5
  client config (`renew_lifetime`, `default_ccache_name`, `kstart`).
- [`nix/profiles/compute.nix`](../nix/profiles/compute.nix) — `sec=krb5` CIFS upcall wiring.
