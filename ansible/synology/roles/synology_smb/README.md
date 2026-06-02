# synology_smb

Manage DSM **SMB global service settings** on the Synology (e4e-nas) from the declarative
spec in [`spec/e4e-nas/smb-globals.yml`](../../../spec/e4e-nas/smb-globals.yml); git is
the source of truth, UI changes are drift
([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works (and why it's not just `raw`)

DSM's `SYNO.Core.FileServ.SMB` **`set` rejects a partial object** (error code 2001), so you
must send the *whole* settings object. [`files/apply_smb.py`](files/apply_smb.py) therefore
**GETs** the full object (API version 3), overlays only the managed keys, and **SETs** it
back — and only when something differs, so re-runs are no-ops. It's shipped via the
`script` module (runs on DSM's Python 3.8, which is below ansible-core's `>=3.9` *module*
floor — same constraint that makes `synology_users`/`synology_shares` use `raw`).

We go through `synowebapi`, not `/etc/samba/smb.conf`, because **DSM regenerates `smb.conf`
from its own config store** — a direct file edit wouldn't survive (the runbook's warning).

## Managed keys (`smb-globals.yml` → DSM field)

| spec key         | DSM field (`synowebapi`)        | notes |
|------------------|---------------------------------|-------|
| `enable`         | `enable_samba` (bool)           | SMB service on/off |
| `min_protocol`   | `smb_min_protocol` (1/2/3)      | `SMB1/2/3` → int; renders to `min protocol` |
| `max_protocol`   | `smb_max_protocol` (1/2/3)      | likewise `max protocol` |
| `server_signing` | `enable_server_signing` (0/1)   | |
| `ntlmv1_auth`    | `enable_ntlmv1_auth` (bool)     | |
| `smb1`           | *(no field)*                    | enforced via `min_protocol >= SMB2` |

The non-SMB pointers in `smb-globals.yml` (ftp/afp/snmp/ntp/…) belong to other roles, not
this one.

## Run

```bash
ansible-playbook playbook.yml                 # apply
ansible-playbook playbook.yml --check --diff  # report drift, change nothing
ansible-playbook playbook.yml --tags export   # drift snapshot → <host>-smb.yml
```

`apply_smb.py` prints `OK no-change` / `WOULD-CHANGE <drift>` (--check) / `CHANGED <drift>`
/ `FAIL <json>`; the task keys *changed*/*failed* off that. In `--check` the script self-
gates to a read-only GET.

## Validation status

Validated on the test rig (`test/`, DSM 7.3.2-86009): forced drift → `--check`
(`WOULD-CHANGE`) → apply (`CHANGED`, `smb.conf` renders `SMB3`/`SMB3`) → re-run (`OK
no-change`). A clean full `ansible-playbook` run awaits the rig getting key auth + NOPASSWD
sudo (password-become over DSM's old sshd is flaky). `apply_smb.py` has pytest unit tests
([`files/test_apply_smb.py`](files/test_apply_smb.py)) covering the type mapping, full-object
set-arg building, and the OK/WOULD-CHANGE/CHANGED/FAIL contract (`pytest files/`, no DSM needed).
