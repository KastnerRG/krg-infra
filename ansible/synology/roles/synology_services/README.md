# synology_services

Manage DSM **file/system services** on e4e-nas from
[`spec/e4e-nas/services.yml`](../../../spec/e4e-nas/services.yml): FTP/FTPS, AFP, SNMP.
Git is truth; UI = drift ([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

[`files/apply_services.py`](files/apply_services.py) (shipped via the `script` module;
DSM py3.8) — three subcommands, each on its own webapi, all full-object set
(partial = err 2001):

| subcommand | API | spec section | role default |
|---|---|---|---|
| `ftp`  | `SYNO.Core.FileServ.FTP` v1 | `ftp:` | both off |
| `afp`  | `SYNO.Core.FileServ.AFP` v1 | `afp:` | off |
| `snmp` | `SYNO.Core.SNMP` v1 | `snmp:` | off |

## SNMPv3 credential bootstrap (separate)

`enable_snmp_v3=true` is accepted by the SET API, but a v3 user can't authenticate until
a USM credential (auth/priv password) is set. That credential is a **bootstrap secret**,
not in this role or spec. Bootstrap path TBD (DSM UI or a `Notification.Mail.Oauth`-style
flow). After the structural set here, run that bootstrap once per rebuild.

## Out of scope (capture gaps)

SFTP, WebDAV, Rsync — the bare `SYNO.Core.FileServ.{SFTP,WebDAVServer,Rsync}` APIs
returned err 102 on the live box; the toggles likely live in a package-provided namespace.
Probe + extend the role once the surface is known. The spec marks them off in the meantime.

## Run

```bash
ansible-playbook playbook.yml                 # apply
ansible-playbook playbook.yml --check --diff
ansible-playbook playbook.yml --tags export   # snapshot → <host>-services.yml
```

## Validation

Unit-tested ([`files/test_apply_services.py`](files/test_apply_services.py)): all three
subcommands' OK / WOULD-CHANGE / CHANGED / FAIL contract + full-object overlay
(unmanaged fields preserved). End-to-end on the DSM 7.3 rig pending (rig down).
