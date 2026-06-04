# synology_ssh

THE breach-fix piece, applied to DSM. Manage SSH/Telnet/SFTP + the sshd
hardening drop-in on e4e-nas from
[`spec/e4e-nas/ssh.yml`](../../../spec/e4e-nas/ssh.yml).

CROSS-REFERENCE: counterpart of `services.openssh.settings` in
[`nix/profiles/base.nix`](../../../nix/profiles/base.nix) and
[`ansible/roles/ssh_hardening`](../ssh_hardening). Anti-lockout guard mirrors
the Debian role: refuse to disable password auth unless
`admin_ssh_keys` (`nix/keys/admins.json`) is populated.

## Order constraint

This role MUST run AFTER `synology_users` so the break-glass admin
(`e4e-admin` on this NAS, since it's E4E hardware) exists with authorized
SSH keys BEFORE password auth is turned off. The `synology_base` composer
enforces that order — do not invoke `synology_ssh` outside that composition.

## Coverage

| Surface | Mechanism | What it owns |
|---|---|---|
| `SYNO.Core.Terminal` v1 (set) | `script:` → `apply_ssh.py terminal` | `enable_ssh`, `ssh_port`, `enable_telnet`, `enable_sftp` |
| `/etc/ssh/sshd_config.d/10-krg-hardening.conf` | `script:` → `apply_ssh.py sshd-drop-in` | `PasswordAuthentication`, `PermitRootLogin`, algorithms (DSM UI has no toggle) |

Both surfaces are driven via the `script:` module because DSM's Python 3.8 is
below ansible's module floor — `template:` and `copy:` don't work on DSM. The
`sshd-drop-in` helper writes the file, runs `sshd -t` for validation, restarts
sshd via `synoservicectl --restart sshd`, and **restores the previous content
if validation fails AFTER replacement** — a broken drop-in can't kill sshd.

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `ssh.enable` | `enable_ssh` |
| `ssh.port` | `ssh_port` |
| `telnet.enable` | `enable_telnet` |
| `sftp.enable` | `enable_sftp` |

If a field name differs on the live box, flip `OUT_KEYS` in
[`files/apply_ssh.py`](files/apply_ssh.py).

## DSM-update fragility

A DSM major upgrade can REVERT the sshd_config drop-in (runbook §1 historical
note). Re-apply `synology_base` after upgrades — it's idempotent, so a no-drift
re-run is cheap and a reverted drop-in is re-asserted in one shot.

## Validation

Unit-tested (`files/test_apply_ssh.py`): OK / WOULD-CHANGE / CHANGED / FAIL
contract, full-object preservation of unmanaged keys, check-mode never-mutates,
port-change drift detection. End-to-end on the rig pending.
