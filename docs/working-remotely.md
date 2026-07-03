# Working remotely (outside the US)

Issue #74 calls the policy "no public access — US is the floor". What
this PR actually delivers is a slightly different (and in some ways
stricter, in other ways looser) shape: there's no geographic gate —
instead, strict-tier hosts are restricted to UCSD + a per-admin override
list, and compute-tier hosts are globally reachable but behaviorally
gated by the **CrowdSec stack** (services.crowdsec +
services.crowdsec-firewall-bouncer, wired up in
[`nix/profiles/base.nix`](../nix/profiles/base.nix)) plus the
[`krg.firewall`](../nix/modules/security/firewall.nix) policy module.

Net result: anyone in UCSD or `ops` reaches strict-tier SSH; anyone in
the world reaches compute-tier SSH but gets banned by CrowdSec if they
trip a scenario or appear on the community blocklist. A country-aware
ban scenario (which would more literally enforce "US is the floor") is
deliberately out of scope here — see the scope section below for the
add-later path. The two tiers:

| Tier | Hosts | Default SSH access |
|------|-------|--------------------|
| Strict (base) | krg-prod, e4e-prod, krg-ldap, krg-vault, krg-deploy, krg-nat | `ucsd` IPSet + `ops` IPSet only (nftables source restriction) |
| Relaxed (compute) | waiter, kastner-ml | globally reachable, **gated by CrowdSec** (community CAPI blocklists + local ssh-bf scenario + trusted-net whitelist) |

Why two tiers: compute hosts are research-user-facing, including visiting
researchers and lab members traveling within the US. Service hosts are
infrastructure and only need to be reachable by admins (who are normally on
campus or in `ops`).

If you're traveling **outside the US** and need SSH to any host:
- **Strict hosts**: blocked unless your source IP is in `ucsd` (e.g.
  through a campus VPN egress) or `ops` (the per-admin manual-override
  slot). The in-guest nftables rule has no other exception path —
  those are the two allowlists `sshSources` unions.
- **Compute hosts**: connection lands at SSHD. Two ways CrowdSec might
  ban you anyway:
  - **Community blocklist hit (CAPI)**: if your source IP has recently
    misbehaved against any of the ~50K worldwide CrowdSec instances,
    you're already in our bouncer's drop set — you'll get a TCP RST or
    silent drop on connect, no SSH prompt.
  - **Local `ssh-bf` scenario** (after-the-fact): the
    `crowdsecurity/sshd` collection bans an IP for 4h after ~10 failed
    SSH auths in 10 min on this host. A single typo won't trigger it;
    a repeated brute-force attempt will. If you're cycling through
    several keys for a fresh `~/.ssh/known_hosts`, you can hit this
    threshold by accident — `ops`-listed IPs are whitelisted
    (s02-enrich parser), so being in `ops` is the safe-button.

Either way, the answer is the same: **add yourself to `ops` before you fly.**

## The escape hatch: `ops`

`nix/networks/trusted.json`'s `ops` IPSet is the manual-override slot.
It serves two roles:

1. **Service hosts (nftables-level)**: `ops` CIDRs are unioned with
   `ucsd` into `krg.firewall.sshSources`, so they bypass the strict-tier
   source restriction outright.
2. **Compute hosts (CrowdSec-level)**: `ops` CIDRs are part of the
   CrowdSec **trusted-nets whitelist** (s02-enrich parser in
   [`nix/modules/security/crowdsec.nix`](../nix/modules/security/crowdsec.nix)).
   Events from `ops` IPs never raise alerts → never produce decisions →
   never end up in the bouncer's nftables ban set. So `ops` travelers
   pass cleanly even when their behavior would otherwise trip a scenario
   (e.g. a few authentication retries before the right key is in `ssh-agent`).

## Before you fly (the 60-second version)

1. Find a stable IP you'll have during your trip. Options, in order of
   preference:
   - Your home / family / hotel public IP. Stable for a week-long trip.
   - A residential proxy / VPN endpoint with a static IP that's
     consistently US-routed — easiest for compute, sufficient even for
     service hosts (still added to `ops`).
   - **Avoid**: airport WiFi, conference WiFi, anywhere the IP rotates
     every few minutes.
2. Open a PR adding your IP to `nix/networks/trusted.json` under
   `ipsets.ops`. Mirror the existing comment style so future-you knows
   which trip it was for:
   ```diff
    "ops": [
      { "cidr": "97.170.130.76",  "comment": "admin remote (chris)" },
      { "cidr": "107.132.34.148", "comment": "admin remote (sean)"},
   +  { "cidr": "203.0.113.42",   "comment": "admin remote (you) — japan trip 2026-Q3" }
    ],
   ```
3. Merge before you leave. NixOS hosts pick it up on the next nightly
   `autoUpgrade` (so merge at least a day before your travel day, or ssh
   in and `nixos-rebuild switch --flake ./nix#<host>` to force pickup
   if you're racing the timer). The CrowdSec whitelist is regenerated
   from `trusted.json` on every rebuild — no separate refresh step.
4. **Confirm from the trip IP** before you depart. If you can't test from
   the trip IP in advance, have a fallback (US-routed mobile eSIM, etc.).

## After you're back

Remove your `ops` entry — same place, just delete the line. Keeps the
override list minimal so a future leak of any one of those IPs has a
small blast radius.

## If you're stuck outside the US and forgot

Two options:

1. **Have someone in-lab add you.** They push from a campus IP (which
   passes the strict policy); the nightly `autoUpgrade` pulls it. If you
   need it *now*, they can ssh to the target host and
   `nixos-rebuild switch` after pushing.
2. **Hop through a US-routed host.** A cloud VPN endpoint that lands in
   US ranges typically passes CrowdSec on compute hosts (the community
   blocklists target known-malicious infra, not generic US VPN IPs). For
   strict hosts you'd still need the endpoint's IP added to `ops` —
   back to option 1.

## Why we don't auto-detect

We considered an "if SSH auth fails from a foreign IP, automatically allow
that IP for 5min" pattern. We rejected it: it has the same attack-surface
as not having any geo policy at all — an attacker who can knock the SSH
port can trigger the auto-allow. The point is to require an admin-driven
decision before opening the door.

## Where the policy is implemented

- Fleet baseline:
  [`nix/profiles/base.nix`](../nix/profiles/base.nix) — enables the
  CrowdSec stack (`krg.crowdsec`, `krg.crowdsecBouncer`) as the sole
  ban layer, and sets `krg.base.serviceHost = true` as the fleet
  default.
- Strict-tier SSH source restriction:
  [`nix/modules/security/firewall.nix`](../nix/modules/security/firewall.nix)
  via `sshSources` (populated from `ucsd` + `ops` in `base.nix` when
  `serviceHost = true`).
- Compute relaxation:
  [`nix/profiles/compute.nix`](../nix/profiles/compute.nix) — sets
  `krg.base.serviceHost = false` (clears sshSources, leaves SSH globally
  open behind CrowdSec).
- CrowdSec scenarios + whitelist:
  [`nix/modules/security/crowdsec.nix`](../nix/modules/security/crowdsec.nix)
  — installs the `crowdsecurity/sshd` collection (ssh-bf scenarios) and
  whitelists `ucsd + sealab + ops + machines` via an s02-enrich parser.
- Explicit globally-public escape hatch:
  `krg.firewall.publicPorts = [ N ];` — operator-explicit, requires
  inline `# reason: ...` comment for PR review. Only legitimate use case
  today is ACME HTTP-01 (krg-vault:80 + krg-prod:80 — Let's Encrypt
  multi-perspective validation requires global reachability).
- Trusted IPSets:
  [`nix/networks/trusted.json`](../nix/networks/trusted.json) — shared
  with the Ansible Proxmox firewall layer; the single source of truth
  for `sshSources` AND the CrowdSec whitelist.

Country-aware ban scenarios (e.g. "drop non-US first packet to port N")
are intentionally NOT wired in this PR — would require
`services.geoipupdate` + `crowdsecurity/geoip-enrich` parser + a
scenario branching on `evt.Enriched.IsoCode`. Add in a follow-up if/when
a country-aware scenario is actually needed.

## Check live state for a host

```bash
# Strict-tier SSH source restriction:
nix eval .#nixosConfigurations.<host>.config.krg.firewall.sshSources
nix eval --raw .#nixosConfigurations.<host>.config.networking.firewall.extraInputRules

# CrowdSec stack health (run on the host):
systemctl status crowdsec crowdsec-firewall-bouncer
sudo -u crowdsec cscli decisions list          # active bans right now
sudo -u crowdsec cscli metrics                 # parser/scenario hit counts
sudo nft list set inet crowdsec crowdsec-blacklists  # what's actually blocked

# Confirm CAPI registration (community blocklist feed) is healthy:
sudo -u crowdsec cscli capi status             # should report "You can successfully interact with Central API"

# (No geoip enrichment in this PR — see "Country-aware ban scenarios" note above
# for the path to add it if a country-aware scenario is later needed.)

# Exercise a CrowdSec scenario against a real sshd journal line
# (NixOS = journald, no /var/log/auth.log):
journalctl -u sshd -n 1 -o cat \
  | sudo -u crowdsec cscli explain --type syslog --log -
```
