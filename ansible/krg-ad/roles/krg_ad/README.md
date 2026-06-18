# `krg_ad` role

Converges the **KRG.LOCAL** Samba AD forest (on `krg-ldap`) to the declarative
spec in [`spec/krg-ad/`](../../../../spec/krg-ad/) by wrapping `samba-tool` on the
DC. See [ADR 0010](../../../../docs/adr/0010-active-directory-structure-as-iac.md).

## What it manages

| Concern | Spec file | samba-tool surface | Authoritative? |
| --- | --- | --- | --- |
| Domain password policy | `password-policy.yml` | `domain passwordsettings set` | yes (drift-only set) |
| Group objects | `groups.yml` | `group add` | **no** — creates only, never deletes |
| Service accounts + membership | `service-accounts.yml` | `group addmembers` | **no** — adds only, never removes |
| Delegated ACL grants | `acls.yml` | `dsacl set` | **no** — adds only, never removes |

The non-authoritative stance is load-bearing: human group membership belongs to
**roster** (`svc_roster`), so a destructive reconcile would wipe roster-set
members on every run. Drift (live groups absent from spec) is *reported*, not
removed. Deleting an AD object stays a deliberate human action.

## How it runs

[`files/apply_ad.py`](files/apply_ad.py) is a stdlib-only Python tool with one
subcommand per concern. The role parses the YAML spec on the control node, ships
each concern as a JSON `--plan` to the DC (`/run/krg-ad/`, tmpfs, no secrets),
and runs the script via the `script:` module. `--check` is threaded through so a
dry run reports drift (`WOULD-CHANGE …`) without mutating the directory.

Unit tests (mock `samba-tool`, no DC needed): `files/test_apply_ad.py` — picked
up by the repo `pytest ansible/ drift/` run.

## Deliberate limitations

- **Group descriptions are set only at creation.** Reconciling the description of
  an *existing* group needs `ldbmodify` (samba-tool has no scriptable setter);
  out of scope to keep the tool simple. Existing groups keep their description.
- **Missing service accounts are a failure, not an auto-create.** Their password
  is a secret (OpenBao); create out-of-band, then the account is a forever no-op.
- **Account lockout policy is not managed** (see `password-policy.yml` + ADR 0010
  "Out of scope").

## Prereq on the DC

`python3` on PATH (added in `nix/modules/samba-ad.nix`) so ansible's modules and
the script shebang resolve. `samba-tool` is already present (the DC package).
