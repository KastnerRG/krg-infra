# synology_security

Manage DSM **firewall + auto-block** on e4e-nas from
[`spec/e4e-nas/security.yml`](../../../spec/e4e-nas/security.yml). Git is truth;
UI = drift.

## Coverage

| subcommand | API | spec section |
|---|---|---|
| `firewall` | `SYNO.Core.Security.Firewall` (enable + profile name) | `firewall:` |
| `fw-conf`  | `SYNO.Core.Security.Firewall.Conf` (port_check) | `firewall.port_check` |
| `autoblock`| `SYNO.Core.Security.AutoBlock` (attempts / within_mins / expire_day / enable) | `auto_block:` |
| `probe-profile` | `SYNO.Core.Security.Firewall.Profile` (read-only) | anti-lockout, runs before `firewall` set |

All full-object set (partial = err 2001). GET → overlay → SET on drift.

## ⚠️ Firewall anti-lockout invariant

Enabling the DSM firewall on a profile with NO rules is a default-deny
posture — DSM blocks all inbound, including the SSH session this play runs
over. The role's per-rule push is still deferred (see "Out of scope" below),
so we can't populate the profile ourselves yet.

The role's first step is therefore a **`probe-profile` read** of the active
profile. If it reports `PROFILE-EMPTY` (or `PROFILE-UNKNOWN`, meaning the API
shape doesn't match our best-known field names), an Ansible `assert` halts
the play with a clear message. To proceed in that case: populate the
profile rules **manually in the DSM UI** first, then re-run. Or temporarily
set `firewall.enable: false` in `spec/e4e-nas/security.yml` and accept
defense-in-depth from the upstream Proxmox/in-guest layers.

## Auto-block allow-list — INFORMATIONAL today

The role's `tasks/main.yml` computes the intended autoblock allow-list from
`nix/networks/trusted.json` (`sealab` ∪ `machines` ∪ `monitoring_host`, deduped)
and **debug-prints it**. It does NOT push it to DSM — the
`SYNO.Core.Security.AutoBlock.Rules` param shape errored 5100 in the live
captures and is deferred. So:

- The list is the operator's reference for what the DSM UI allow-list
  SHOULD contain — set it by hand to match for now.
- `auto_block.expire_day: 0` (permanent block) means a misfire is a manual
  unblock chore until the allow-list push lands.

Tracked in plan.md "Deferred items".

## Out of scope (capture gaps — TODO)

- **Firewall rule list** — `SYNO.Core.Security.Firewall.Rules load` errored 120 on the
  live box; need the correct param shape (likely `profile_name=` or a different key)
  before encoding rules.
- **Firewall profile detail** — `Firewall.Profile get` errored 120; same.
- **Geoip** — `Firewall.Geoip get` errored 114.
- **Auto-block allow/deny lists** — `AutoBlock.Rules download` errored 5100; need the
  right `listType=` value. Spec's `allow_list_ref` points at `trusted.json` for DRY.

Each needs one more rig-side probe to confirm params, then a subcommand here.

## Validation

Unit tests cover the three subcommands' full lifecycle. End-to-end on the rig pending.
