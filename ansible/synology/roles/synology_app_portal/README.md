# synology_app_portal

Manage DSM **Application Portal** on e4e-nas from
[`spec/e4e-nas/app-portal.yml`](../../../spec/e4e-nas/app-portal.yml).

## Coverage

| subcommand | API | model |
|---|---|---|
| `config`         | `SYNO.Core.AppPortal.Config` v1 (set)             | full-object |
| `reverse-proxy`  | `SYNO.Core.AppPortal.ReverseProxy` v1 (list/create/update/delete) | declarative list sync by id/alias |
| `access-control` | `SYNO.Core.AppPortal.AccessControl` v1 (list/create/update/delete) | declarative list sync by id/alias |

**List sync semantics:** the helper diffs live entries vs spec entries by `id` (falling
back to `alias`/`name` when the spec entry hasn't acquired an id yet). New entries get
`create`, extras get `delete`, changed entries get `update`. Empty spec list → all live
entries deleted. Live = capture from 2026-05-28 showed both lists empty.

## Out of scope (this iteration)

- **Per-app portal entries** (`SYNO.Core.AppPortal` set/list): the entry shape (alias,
  fqdn, HSTS, ACL ref) needs design before we declaratively sync portal apps. The
  spec's `portal_apps:` block is documentation today.

## Validation

Unit-tested ([`files/test_apply_app_portal.py`](files/test_apply_app_portal.py)): the
declarative-list-sync semantics (create/update/delete classification), the config
subcommand's full-object behavior, OK/WOULD-CHANGE/CHANGED/FAIL contract. End-to-end on
the rig pending. Live capture had both lists empty — apply with empty spec is a no-op.
