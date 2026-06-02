# synology_base

The "secure + monitored + enrolled by default" baseline composer that EVERY
managed DSM host gets. Mirrors `nix/profiles/base.nix` and
`ansible/roles/base/tasks/main.yml`.

This role contains NO logic of its own — it's a load-bearing-order composition
of the per-concern `synology_*` primitives. When you change a baseline
behaviour on any other layer (nix or Debian/ansible), mirror it here.

## Composition (in execution order)

| # | Role | What it owns |
|---|---|---|
| 1 | [`synology_dsm_system`](../synology_dsm_system) | hostname / gateway / DNS — make the box reachable |
| 2 | [`synology_users`](../synology_users) | break-glass admin + home service + disable admin/guest |
| 3 | [`synology_ssh`](../synology_ssh) | key-only SSH, no root, no Telnet/SFTP (breach fix) |
| 4 | [`synology_security`](../synology_security) | DSM firewall + autoblock |
| 5 | [`synology_external_access`](../synology_external_access) | QuickConnect/UPnP off (no relay around firewall) |
| 6 | [`synology_dsm_web`](../synology_dsm_web) | HSTS / HTTP2 / TLS Modern |
| 7 | [`synology_services`](../synology_services) | FTP/AFP off, SNMPv3 on |
| 8 | [`synology_notifications`](../synology_notifications) | mail/SMS/push channels |
| 9 | [`synology_security_advisor`](../synology_security_advisor) | DSM-native vuln/config scan (replaces OEC — ADR 0006) |
| 10 | [`synology_dsm_updates`](../synology_dsm_updates) | hotfix-security auto-install |
| 11 | [`synology_ad`](../synology_ad) | KRG.LOCAL domain join (LAST — failure must not lock out local admin) |

## Anti-lockout invariants

- Step 2 (`users`) MUST run before step 3 (`ssh`) so the break-glass admin
  (`e4e-admin` on this NAS, since it's E4E hardware) exists with authorized
  keys before password auth is disabled. Same rule the Debian baseline applies
  for `krg_admin` → `ssh_hardening`.
- Step 11 (`ad`) MUST run AFTER 2 + 3 so a bad winbind idmap or `allowed_groups`
  filter can't lock out local accounts.
- Step 5 (`external_access`) MUST run AFTER 4 (`security`) so the perimeter is
  up before we make sure nothing punches around it.

## Post-DSM-upgrade healthcheck

A DSM major upgrade can revert the sshd_config drop-in written by
`synology_ssh` (runbook §1 historical note). After a DSM upgrade, re-run
`synology_base` — it's idempotent, so a no-drift re-run is cheap and a reverted
drop-in is re-asserted in one shot.
