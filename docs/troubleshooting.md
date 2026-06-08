# Troubleshooting & known issues

Symptom-first recovery guide for the gotchas this fleet has actually hit — the
ones that otherwise live only in code comments and tribal memory. Each entry is
**Symptom → Cause → Fix**. For full rebuilds see
[disaster-recovery.md](disaster-recovery.md); for the AD join see
[joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md).

> **First instinct on any NixOS host:** you can almost always roll back. Pick an
> earlier generation at the GRUB menu, or `nixos-rebuild --rollback switch`. The
> break-glass `krg-admin` (local, key-only, home off `/home`) logs in even when AD
> and NFS are down — keep it working.

---

## Boot / early boot

### Box hangs at "Create System Files and Directories" or switch-root (waiter)
**Symptom:** waiter freezes early in boot; console shows *"Refusing to run in
unsupported environment where /usr/ is not populated"*, and it bricks **every**
generation (not just the new one).
**Cause:** impermanence rolls the root back to the empty `@blank`; systemd 258's
PID1 hard-checks that `/usr` is populated and freezes before tmpfiles can create
`/usr/bin/env`. ([`impermanence.nix`](../nix/modules/impermanence.nix) normally
reseeds it in initrd — this bites if that unit is missing/broken.)
**Fix / recovery:**
1. At GRUB, edit the entry and add `boot.debug1mounts` (drops to a shell after
   `/sysroot` is mounted).
2. Recreate the link so PID1's check passes:
   `mkdir -p /sysroot/usr/bin && ln -s /nix/var/nix/profiles/system/sw/bin/env /sysroot/usr/bin/env` (any valid `env` target works — even a dangling link satisfies the check), then continue boot.
3. Once up, redeploy current `main` so the `populate-usr-bin-env` initrd unit is
   present again.

### `zpool` won't import after a reboot / "pool was previously in use from another system"
**Symptom:** box won't boot; root pool fails to import.
**Cause:** `forceImportRoot/All = false` ([`zfs.nix`](../nix/modules/zfs.nix)) — the
pool imports only when the running `networking.hostId` matches the one that last
had it. A changed hostId, or a pool that wasn't cleanly exported (power loss), locks
it out.
**Fix:** from a rescue/installer environment, `zpool import -f nvmepool` (and
`scratchpool`). Then make the running hostId match the committed one. **Prevention:**
always `zpool export -a` before rebooting during an install, and treat the committed
hostId as load-bearing (never edit casually, never reuse on another box).

---

## AD / login

### AD sudo "rejected", journald blind, SSSD offline — right after a deploy
**Symptom:** AD users suddenly can't `sudo` ("authentication rejected"), the journal
looks empty/discontinuous. Hit 2026-05-22 when the 04:00 auto-upgrade pulled a
pre-merge `main`.
**Cause:** the deployed generation was **missing the `/persist` bind units**, so
`/etc/krb5.keytab`, `/etc/machine-id`, and the SSH host-key binds were torn down →
SSSD goes offline, journald loses its stable machine-id.
**Fix:** redeploy current `main` (which has the persist binds).
**Recovery gotcha:** do **not** pre-copy files into `/etc` to "help" — the bind
mount refuses to mount over a non-empty file. Let the persist units own them.

### Brand-new AD user gets "Permission denied (publickey)" (cached users are fine)
**Symptom:** an existing/recently-logged-in user works, but a *new* AD user is
rejected at the key stage.
**Cause:** SSSD is flapping **offline** because it can't resolve `krg.local`. SSSD's
own resolver reads `/etc/resolv.conf` directly and **ignores** the `/etc/hosts` pin
— so unless the DC is a real nameserver, `krg-ldap.krg.local` won't resolve.
**Fix:** ensure the DC is the **primary** resolver. The module sets this
(`networking.nameservers` `mkBefore [ serverIp ]`,
[`sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)); verify on the box:
```bash
head -1 /etc/resolv.conf            # should be: nameserver 137.110.161.109 (krg-ldap)
host -t SRV _ldap._tcp.krg.local    # must resolve
systemctl restart sssd
```
(Distinct from a missing **join** — a *deployed-but-unjoined* host shows the same
error; see [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md).)

### All AD users denied with "network home is not mounted" (waiter)
**Symptom:** AD logins refused with a message about `/home` not being mounted;
`krg-admin` still works.
**Cause:** **working as designed.** fabricant (NFS) is down, so `/home` (a `nofail`
mount) didn't mount; the login gate ([`nfs-home.nix`](../nix/modules/nfs-home.nix))
denies AD users rather than letting `pam_mkhomedir` create an ephemeral home that
the next reboot would wipe.
**Fix:** bring fabricant/NFS back, then **mount `/home` explicitly** — the `nofail`
mount does **not** auto-mount on later access:
```bash
sudo mount /home          # or reboot once fabricant is up
mountpoint -q /home && echo ok
```

### AD user can log in but can't use the GPU (`/dev/nvidia*` permission denied)
**Symptom:** login works, `nvidia-smi` / CUDA fails with permission denied.
**Cause:** GPU device access is gated on the local `cuda` group (gid 65533), not a
login group. AD users can't be placed in a fixed-GID local group, so a `cuda-group-sync`
unit bridges the **"GPU Users"** AD group into `cuda` on boot + every 10 min
([`nvidia.nix`](../nix/modules/hardware/nvidia.nix)). After a `switch` there's a
≤10-min gap, or the user isn't in "GPU Users".
**Fix:**
```bash
sudo systemctl start cuda-group-sync     # apply immediately
getent group cuda                        # confirm the user is now a member
```
If still empty, add the user to the **"GPU Users"** AD group (separate from login
access) — see [creating-a-user.md](creating-a-user.md). Note: an emptied/unresolvable
AD group is treated fail-*safe* (membership left unchanged) — only a group that
resolves-but-is-empty revokes.

---

## Scratch — waiter `/scratch/krg`

> Describes the **greenfield** design ([scratch-greenfield.md](scratch-greenfield.md)):
> a plain ZFS mount on `scratchpool` (no FUSE), with a daily NFS overflow. The old
> autotier (FUSE) failure modes are gone with the tool.

### A file under /scratch is a symlink into `/srv/scratch-cold/...` / reads got slow
**Symptom:** `ls -l` shows a file is a symlink to the cold NFS area; reading it is slow.
**Cause:** it wasn't accessed for a while and the overflow job demoted it to NFS to
free local space. **Nothing is lost** — the data is on fabricant.
**Fix:** pull it back to fast storage — `scratch-restore <path>` (or a directory).

### `scratchpool` is full / overflow isn't freeing space
**Checks:**
```bash
zpool list scratchpool                       # CAP% — overflow fires above 85%
systemctl status scratch-overflow-krg.timer  # daily timer enabled?
mountpoint -q /srv/scratch-cold/krg && echo cold-ok   # FAIL-CLOSED if not mounted
sudo scratch-overflow --pool scratchpool --scratch /scratch/krg \
  --cold /srv/scratch-cold/krg --high 85 --low 75 --min-age-days 14 --dry-run
```
**Common causes:** the cold NFS area isn't mounted (fabricant down) so the unit
**won't start by design** (`RequiresMountsFor`); or every candidate was accessed
within the last 14 days (`--min-age-days`), so nothing is eligible to demote.

### Every write to /scratch fails with EACCES (for all lab members)
**Symptom:** `ls`/`cd` work, but creating any file under `/scratch/krg` fails.
**Cause:** `/scratch/krg` hasn't been `chgrp`'d to the lab group yet — the perms step
couldn't **resolve** `Kastner Research Group`, so it left the tree root-owned/admin-only
(tolerant, by design). The group already exists in AD; the usual reason it doesn't
resolve is SSSD/AD lookup not being healthy yet (host not joined, DNS can't reach the
DC, or `sssd.service` down — see the SSSD/DNS-flap note above). (This is a **real 3770**
now — the old autotier `2771`/`o+x` workaround is gone.)
**Fix:** make sure the group resolves — `getent group 'Kastner Research Group'` returns
a line (host joined, DNS to the DC working, `sssd.service` active) — then
`systemctl restart krg-scratch-perms-krg`; verify:
```bash
stat -c '%a %G' /scratch/krg                 # want 3770 'Kastner Research Group'
```

---

## Storage / hardware

### waiter `sdb` (ata3) SATA link errors in dmesg
**Symptom:** recurring SATA bus/link errors for `sdb` (a `scratchpool` data leg),
first seen 2026-05-22.
**Status:** **letting it ride** — `scratchpool` is ONLINE with 0 errors and only
holds regenerable scratch. The box can't be physically serviced right now.
**Cautions:** do **not** scrub a flapping disk (a scrub hammers it). Note the
greenfield `scratchpool` data is **striped (no redundancy)** — if `sdb` fails the
pool is lost and **regenerated** (accepted; the data is regenerable). `smartd` is now
enabled ([`hosts/waiter/default.nix`](../nix/hosts/waiter/default.nix)) for advance
warning; pool health also goes to Prometheus via the textfile collector
([`zfs.nix`](../nix/modules/zfs.nix)). Watch `zpool status scratchpool`.

---

## Security agents (OEC: Qualys + Trellix)

### `xagt.service` fails after a rebuild (`status=245`, flapping)
**Symptom:** a `nixos-rebuild switch` fails with `the following units failed:
xagt.service`; the unit is `activating (auto-restart)`, `ExecStart=/opt/fireeye/bin/xagt
-M DAEMON` exited `status=245`, yet a `xagt -M DAEMON` is still alive in the cgroup.
**Cause:** the vendor unit uses `KillMode=process`, so stopping xagt kills only the
launcher and leaves the agent **daemon** running. When a rebuild restarts the unit,
the fresh `xagt -M DAEMON` finds an instance already running and exits non-zero, and
`Restart=always` flaps it — which `switch-to-configuration` reports as a failed unit,
failing the deploy.
**Fix (in tree):** `restartIfChanged = false` on `xagt` (and `qualys-cloud-agent`) —
nixos-rebuild no longer bounces the self-managing EDR daemons; they still start on
boot/first-enroll and still recover from real crashes via the unit's `Restart=always`.
**Recovering a host already stuck in the flap** (one-time, break-glass — the live
unit's own restart loop won't self-heal): stop the unit, kill any stray daemon, start
one clean instance:
```bash
sudo systemctl stop xagt
sudo pkill -f '/opt/fireeye/bin/xagt' || true
sleep 2
sudo systemctl start xagt
systemctl is-active xagt   # expect: active
```

### `oec-install` fails: `gzip: stdin: not in gzip format`
**Symptom:** `oec-install.service` fails immediately at extraction with
`gzip: stdin: not in gzip format` / `tar: Child returned status 1`, failing the
`nixos-rebuild switch` (and the deploy).
**Cause:** despite the `.tgz` name the vendor archive is a **plain (uncompressed)
tar** — its first bytes are the `trellixandqualys/` tar header, not the gzip magic.
`tar -xzf` forces gzip and rejects it.
**Fix (in tree):** the module extracts with `tar -xf` (auto-detect), which handles
plain tar / gzip / xz transparently; `deploy-nixos.sh` also sanity-checks the
control-node archive with `tar -tf` before staging. If you re-roll the archive,
either format is fine — just keep it a tar.

### `oec-install` doesn't enroll on NixOS
**Symptom:** the OEC oneshot runs but Qualys/Trellix don't come up.
**Cause:** the vendor archive ships **unpatched Ubuntu binaries** that assume an
FHS layout; the current NixOS module runs them under `nix-ld`/`envfs`, which doesn't
fully satisfy them — this path is **not yet validated on-box**.
**Notes:** the installer archive (live credentials, **gitignored**) must sit at
`/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz`. Force a reinstall by
removing the sentinel `/var/lib/krg/oec/.installed` and rebuilding (see the OEC
section of [nix/README.md](../nix/README.md)). On Debian/PVE the Ansible
`oec_qualys_trellix` role is the counterpart (set `oec_installer`).

### A deploy fails on "OEC security daemons not both active"
**Symptom:** the push-to-main deploy fails in the NixOS step ("OEC security daemons
not both active") or the Ansible step ("Verify both OEC daemons are active").
**Cause (expected):** the OEC agents are a **hard gate** in the deploy
([deploy/README.md](../deploy/README.md) *OEC*, #22) — `deploy-nixos.sh` stages the
archive + verifies `qualys-cloud-agent` + `xagt` are active on every host, and the
Ansible role does the same on the Proxmox hosts. A host where either daemon is down
fails the whole deploy by design (no silently-unhardened machine). The likely
underlying reason is the unvalidated nix-ld path above — debug `oec-install` /
`qualys-cloud-agent` / `xagt` on the offending host, not the deploy script.
**Control-node precondition:** if the archive is absent at `OEC_INSTALLER`
(`/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz`), the deploy
fails immediately with a FATAL before touching any host — stage it out-of-band.

### Validating OEC reporting without console access
**Context:** the only *authoritative* proof an agent reports is the campus Qualys /
Trellix console — and we don't have access to it (#22). Short of that, the host
itself gives strong circumstantial evidence that the agent is genuinely talking to
its backend, not just running. The deploy's hard gate stays at `systemctl is-active`
(robust, version-independent); the checks below are a **manual confidence pass**, not
a deploy gate (agent log formats / the `xagt` status CLI vary by version, so gating
on them would be brittle). Run them on the host (`krg-admin` + `sudo`) after enrollment.

**Qualys Cloud Agent** — the activation itself is a network round-trip (it contacts
the Qualys POD and *fails* on bad creds / no route), so a clean `oec-install` already
means it reached the tenant once. Ongoing reporting:
```bash
# 1. Registered → got an AgentID (empty/absent = never registered)
sudo ls -l /etc/qualys /var/spool/qualys 2>/dev/null
# 2. Log shows activation + periodic manifest download / upload ("sent"/"uploaded")
sudo tail -n 50 /var/log/qualys/qualys-cloud-agent.log
# 3. Live TLS connection out to the Qualys gateway POD
sudo ss -tnp | grep -i qualys
```

**Trellix HX / xagt** — `main.db` existing already means enrollment reached the
appliance (the module gates `xagt.service` on it). For *ongoing* reporting, the
clearest signal is a live connection to the HX server baked into `agent_config.json`:
```bash
sudo ls -l /var/lib/fireeye/xagt/main.db            # enrolled
sudo ss -tnp | grep -i xagt                          # established conn to the HX manager
sudo ls -lt /var/lib/fireeye/xagt/ /opt/fireeye/     # recent log/state activity
```

**Limitation:** none of this proves the data landed in *our* tenant (logs can say
"uploaded OK" into a tenant we can't see). The only ways to close that gap fully are
console access or **asking whoever owns the campus tenant (UCSD ITS security) to
confirm the hosts appear** — a one-line email once enrolled. Until then this residual
verification stays open by design.

## Docker / containers

### A nightly update killed running containers (the docker-daemon-bounce rule)

**HARD RULE: the docker daemon must never restart on `nixos-rebuild`** — only on a
deliberate `systemctl restart docker` or a reboot during a planned maintenance
window. Enforced **fleet-wide** for every host that enables `krg.docker` (all
compute *and* service hosts — it lives in `nix/modules/docker.nix` under
`mkIf cfg.enable`, so a newly-built compute box inherits it with no extra config):

```nix
systemd.services.docker.restartIfChanged = false;   # modules/docker.nix
```

plus `system.autoUpgrade.allowReboot = false` in `nix/profiles/base.nix` (also a
fleet default), which closes the other nightly restart vector — a reboot.

**Why** (2026-06-08): a nightly `nix flake update` advanced the lock, which rebuilt
docker (*same* 28.5.2 version, new store path because its deps changed) →
`nixos-rebuild switch` restarted `docker.service` → the daemon bounce killed every
running container, including experiments that had been running on waiter for ~1.5
weeks.

**Consequence:** docker engine/config changes (e.g. the 28→29 upgrade in the
nixos-26.05 PR) take effect only on an explicit restart/reboot — schedule them in a
maintenance window. Verify a host is protected:

```bash
nix eval .#nixosConfigurations.<host>.config.systemd.services.docker.restartIfChanged   # false
nix eval .#nixosConfigurations.<host>.config.system.autoUpgrade.allowReboot             # false
```
