# synology_quotas

Per-share (and optional per-user) quota policy on e4e-nas from
[`spec/e4e-nas/quotas.yml`](../../../spec/e4e-nas/quotas.yml). Wraps the
`synoquota` CLI via [`files/apply_quotas.py`](files/apply_quotas.py)
(script:, DSM py3.8).

CROSS-REFERENCE: counterpart of `ansible/roles/zfs_limits` (ZFS quota /
reservation on Proxmox) and `nix/modules/scratch.nix` per-dataset `quota=`
properties. Same intent: cap regenerable / user-facing storage so essential
data wins.

## Coverage

| subcommand | CLI | model |
|---|---|---|
| `share` | `synoquota --get-share` / `--set-share` / `--clear-share` | per-share, GiB + hard/soft |
| `user` | `synoquota --get` / `--set` / `--clear` | per-user-per-volume, GiB + hard/soft |

`size_gib: 0` means "no quota" — the role REMOVES an existing quota in that
slot if any. `hard: true` blocks writes when full; `false` is soft (warn-only,
notification goes through `synology_notifications`).

## Live capture flagged ~8,900 quota rows on the old box

That's mostly per-user history we don't want to drag forward. Port the
POLICY (per-share caps + the small set of user quotas that matter), not the
history.

## Field/CLI mapping (best-known; verify on first rig apply)

The `CMDS` table in
[`files/apply_quotas.py`](files/apply_quotas.py) is best-known from the
live capture's `synoquota --user-list` evidence and the help-text shape. If
first-apply shows `synoquota` exits with bad-flag, flip `CMDS` — single
source of truth.

Output parser tolerates GB/GiB/TB/TiB/MB/MiB and the `(Hard)`/`(Soft)` suffix.
If it can't parse the current quota, the script FAILS rather than guessing —
better noisy than over-applying spec drift on a misread state.

## Validation

Unit-tested (`files/test_apply_quotas.py`): parser against several DSM output
shapes, OK / WOULD-CHANGE / CHANGED / FAIL contract, drift on size + hard
flip, clear vs noop when size 0, check-mode never-mutates, fail-on-unparseable.
End-to-end on the rig pending.
