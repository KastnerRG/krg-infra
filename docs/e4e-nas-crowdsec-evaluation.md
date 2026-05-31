# CrowdSec on e4e-nas — evaluation (no implementation)

**Decision: do NOT add CrowdSec to the NAS.** The NAS uses the
DSM-native security stack instead:

1. **DSM AutoBlock** — SSH brute-force protection (already configured
   in [`spec/e4e-nas/security.yml`](../spec/e4e-nas/security.yml):
   3 attempts in 24h, no expiry).
2. **DSM Firewall** — source-restriction rules per-profile (rules TBD
   pending live capture).
3. **DSM Firewall.Geoip** — country-allowlist (US-only) enforcement
   for everything not covered by the explicit allow-list rules. Spec
   target now in `security.yml`; implementation pending the API capture.

Notably, **#3 actually delivers issue #74's "US is the floor" policy
literally** — the NAS's protection model is in some ways stricter than
the Linux fleet's, where CrowdSec on the rest of the fleet doesn't have
a country gate (we dropped MaxMind/geoip-enrich from PR #91 because no
scenario branched on country). DSM's native geoip gate exists at the
firewall layer; we just have to turn it on.

This doc captures the analysis so the same question doesn't need to be
re-asked from scratch later.

## Context

PR #91 wired CrowdSec on every NixOS host; PR #92 mirrored it on every
Debian/PVE host. The natural next question: should the Synology NAS get
the same treatment? Especially because — unlike the Proxmox host and
its VMs — **the NAS does have a planned public IP** (132.239.17.124 on
UCSD's `132.239.17.0/16`), so the "no public SSH anyway" argument that
deferred CrowdSec on `fabricant` doesn't apply here.

## Threat model

What's actually exposed once eth0 is cabled:

| Service | Port | Exposure | Existing protection |
|---|---|---|---|
| SSH | configurable | UCSD-public | DSM hardened sshd drop-in + AutoBlock |
| DSM web UI | 5000/5001 | LAN by DSM firewall (planned) | DSM AutoBlock + per-IP rate limiting |
| SMB | 445 | LAN by DSM firewall | DSM AutoBlock + SMB3-min + signing |
| NFS | 2049 | fabricant only (export ACL) | NFS export ACL |
| FTP/AFP | — | hardened off | n/a |

**Primary attack surface = SSH.** Web UI and SMB are LAN-only behind
DSM Firewall once we finish bring-up; NFS is host-restricted.

## What CrowdSec would add vs DSM AutoBlock

| Capability | DSM AutoBlock | CrowdSec (if installed) |
|---|---|---|
| SSH brute-force | yes (3 attempts in 24h, no expiry) | yes (ssh-bf: ~10 in 10 min, 4h) |
| DSM web UI brute-force | yes | only if we wired log acquisition |
| SMB / FTP / etc. brute-force | yes | only if we wired log acquisition |
| Community CTI (pre-bans known-malicious) | no | yes (CAPI, ~30K-50K IPs) |
| Country-aware bans | no (geo blocking yes; geo-aware scenarios no) | only if we added `crowdsecurity/geoip-enrich` + a scenario |
| Fleet-wide ban sharing | no | yes (CAPI sharing on by default) |
| Allow-list from `trusted.json` | informational only today (Rules API gap, see `security.yml`) | yes (parser whitelist) |

The CrowdSec wins on paper: community CTI + fleet sharing + uniform
operational model with the rest of the fleet. AutoBlock's wins:
**built into DSM**, no integration risk, already configured.

## Why "don't add" anyway

### Path A: native package — unavailable

There's no official CrowdSec package for DSM, and SynoCommunity (the
de-facto third-party packager) doesn't ship one as of this writing.
Building a native DSM package is non-trivial: CrowdSec is Go, requires
SQLite (DSM has it), but the `spk` packaging requires bootstrap scripts,
firewall integration shims, etc. Not a one-evening project.

### Path B: Docker container (Container Manager) — partial story

DSM 7.x's Container Manager (formerly Docker) runs the official
`crowdsecurity/crowdsec` image fine. Acquire `/var/log` (mounted into
the container) for sshd auth, run scenarios, post decisions to its
internal LAPI. CAPI registration works the same.

**But: the bouncer is the hard part.**
[`crowdsec-firewall-bouncer-iptables`](https://github.com/crowdsecurity/cs-firewall-bouncer)
inserts a `CROWDSEC` chain into iptables INPUT. Inside a Container
Manager container with `CAP_NET_ADMIN`, that mechanically works — but
the rules land in the host's iptables alongside DSM's own
`synofirewall`-managed chains. DSM periodically re-asserts its
ruleset (on any DSM Firewall config change, reboot, package update,
`synopkgctl restart pkgctl-synofirewall`), which clears any rules
outside its managed chains. The CROWDSEC chain would survive briefly
(the bouncer re-inserts every 10s by default), but you'd be in a
permanent low-grade fight with DSM's firewall manager.

There IS a viable middle ground: **run CrowdSec in a container for
observation only** (CAPI pulls + logs + dashboard via the upstream
console), with no bouncer — see what it would have caught, get
fleet-wide visibility, no enforcement. Useful for monitoring; not
real protection.

### Path C: DSM-API bridge — would have to be written

A custom bouncer that pulls CrowdSec decisions and pushes them into DSM
AutoBlock's deny-list via DSM's web API (`SYNO.Core.Security.AutoBlock.Rules`).
Issues:
- That API errored `5100` in our live captures (per
  [`spec/e4e-nas/security.yml`](../spec/e4e-nas/security.yml) honesty
  note); we don't have a working push for it yet.
- DSM AutoBlock's deny-list is intended for a few hundred entries, not
  CAPI-scale (~30K-50K).
- Custom code, custom failure modes, only one consumer.

### Path D: DSM AutoBlock alone — what we have

DSM AutoBlock is built in, covers SSH (the primary attack surface),
supports an allow-list (pending the Rules API plumbing per the spec
file's note), and works reliably. The cost: no community CTI, no
fleet visibility.

For a single NAS with a known attack surface, the marginal CrowdSec
benefit doesn't outweigh the integration risk on a closed appliance OS.

## What we should do instead

1. **Turn on DSM Firewall.Geoip** with `allow_countries: [US]`. Spec
   target now in [`spec/e4e-nas/security.yml`](../spec/e4e-nas/security.yml);
   needs the API capture (the live-probe errored 114 on get) before
   `apply_security.py` can push it. This is the load-bearing
   recommendation — it's the literal "US is the floor" enforcement,
   built into DSM, no third-party packages.
2. **Finish the DSM Firewall rules** in the same spec file — the
   profile rules are still `TODO from live load`. Restrict DSM web UI
   to UCSD nets, SMB to sealab+e4e users, SSH to ucsd+ops (matches the
   nix fleet's `sshSources` pattern). These rules take precedence over
   geoip in DSM's filter chain, so the per-admin `ops` allow-list keeps
   working as the manual-override slot.
3. **Close the AutoBlock Rules API gap** the spec file calls out — get
   the allow-list actually pushed to DSM so a misfire doesn't strand
   a sealab/admin IP permanently.
4. **Document the security delta** vs the rest of the fleet: no
   community CTI feed, no fleet-wide ban sharing — but ALSO note that
   geoip gating goes further than the Linux fleet has today (since we
   dropped MaxMind there per PR #91's scope reduction). Net posture
   is different-shaped, not strictly worse.

## Revisit conditions

Consider CrowdSec on the NAS later if any of these change:

- **SynoCommunity ships a CrowdSec spk** — flips path A from impractical
  to easy; would handle the firewall-bouncer integration with DSM
  awareness.
- **NAS exposes more services publicly** (Plex / Synology Drive / Photo
  Station / a hosted web app) — increases the attack surface beyond
  what AutoBlock cleanly covers.
- **We standardize on Docker-everywhere on the NAS** — running CrowdSec
  in Container Manager for observation-only becomes cheap if we already
  have a container workflow, and the fleet-CTI visibility alone might
  be worth it even without enforcement.
- **A targeted attack happens against the NAS** that CrowdSec would
  have caught — concrete forcing function.

## Out of scope

- **DSM Security Advisor** — separate DSM feature, already in
  `spec/e4e-nas/security.yml` (was the `Apply` task in the bring-up
  apply plan).
