# 0006. No OEC (Qualys Cloud Agent + Trellix HX) on DSM

**Status:** Accepted · **Date:** 2026-05-28

## Context

[`nix/modules/security/oec-qualys-trellix.nix`](../../nix/modules/security/oec-qualys-trellix.nix)
and [`ansible/roles/oec_qualys_trellix`](../../ansible/roles/oec_qualys_trellix)
install the UCSD-ITS-mandated endpoint stack (Qualys Cloud Agent + Trellix HX)
on every host the lab manages. That stack assumes a general-purpose
**Debian/RHEL Linux endpoint** — installer archives are RPM/DEB, the kernel
modules and `xagt` daemon link against system glibc, agent updates ride apt/yum.

The Synology DSM appliance (`e4e-nas.ucsd.edu`) does NOT fit those assumptions.
DSM is a curated, vendor-managed firmware: closed package format (`spk`), no
apt/yum, system libraries are not API-stable across DSM releases, and
arbitrary `xagt`-style daemons are unsupported by Synology — they will either
be killed by the DSM update process or silently broken when DSM swaps a
library out from under them.

Meanwhile, DSM ships its own analogues for the high-level concerns OEC covers:

| OEC concern | DSM-native equivalent (this repo) |
|---|---|
| Vuln scan + config-hardening checks | `synology_security_advisor` → DSM Security Advisor (scheduled scan, email on finding) |
| Endpoint patching (security updates) | `synology_dsm_updates` → `hotfix-security` auto-install policy |
| Brute-force / dictionary attack protection | `synology_security` → DSM AutoBlock (3 attempts / 24h) + in-DSM firewall |
| Outbound relay / NAT-pierce surface | `synology_external_access` → QuickConnect + UPnP off |
| Off-box DR copy | `synology_hyper_backup` (separate concern from OEC; called out for completeness) |

Together these match OEC's *intent* — periodic posture check, automatic
patching, attack-surface reduction — on Synology's own terms.

## Decision

`e4e-nas` does **NOT** run Qualys Cloud Agent or Trellix HX. The DSM-native
roles above are the equivalent posture. The Debian / NixOS hosts continue to
run OEC unchanged (`base.nix` / `ansible/roles/base`).

A **compliance carve-out** must be filed with UCSD ITS for the "OEC on every
endpoint" line: NAS / storage appliances need a documented exception. Cite
this ADR.

## Consequences

- **Less coverage from the campus SOC for this host.** The trade-off accepted:
  Synology's signal/noise on its own platform is much better than Qualys's
  Debian/RHEL CVE feed mismatched against DSM's curated packages (a
  CVE-flooded report nobody triages is worse than a curated one operators
  read).
- **Less DSM-update fragility.** Stock DSM behaves predictably across upgrades;
  a sideloaded `xagt`-style daemon is a constant DSM-upgrade hazard. Both
  layers' synology_ssh roles already note that DSM updates can revert sshd
  drop-ins — `xagt` would be in the same hazard class with much worse blast
  radius if it broke.
- **Compliance paperwork required.** Until the carve-out is filed and acked,
  the NAS shows as "missing OEC" in the campus inventory. Not technical debt —
  organizational debt with a known path.
- **Visibility through the DSM channel, not the Qualys console.** The
  `synology_notifications` email channel (configured per `notifications.yml`)
  is where Security Advisor findings land. Make sure the destination address
  is one ops actually reads.

Related: ADR 0001 (git as the source of truth for DSM config — supports
"if it's not in `synology_*` it's drift, including any future OEC sideload"),
[`synology_security_advisor/README.md`](../../ansible/synology/roles/synology_security_advisor/README.md),
[`synology_dsm_updates/README.md`](../../ansible/synology/roles/synology_dsm_updates/README.md),
the runbook `docs/e4e-nas-dsm.md` §6 hardening notes.
