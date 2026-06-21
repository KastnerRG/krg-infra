# 0012. Endpoint device management: lab-owned control plane, split Fleet (MDM) + flake (NixOS)

**Status:** Accepted · **Date:** 2026-06-20

## Context

The lab is acquiring a mixed fleet of **lab-owned** end-user devices — loaner
laptops (NixOS, Windows, macOS), plus mobile (iOS/iPadOS, Android) — lent to
students and taken into the field. These devices **get lost/stolen** and carry
**unpublished research / campus IP** that must be protected.

UCSD ITS provides Microsoft **Intune** as the campus MDM
(`blink.ucsd.edu/.../intune-mdm`), but it is a poor fit for this need on its own:
- Enrollment is **mandated only for devices accessing trusted resources** (wired /
  UCSD-PROTECTED); off-campus loaners on home networks are exempt.
- The documented program covers **Windows + macOS only** — no Linux, and iOS/Android
  are not in scope. It is the campus delivery vehicle for **Qualys + Trellix**, and
  it excludes remote wipe on BYOD.
- For a stolen-IP incident the lab needs to **act on its own timeline**, not file an
  ITS ticket.

Export-controlled software is deliberately kept **off** these devices, so it is not
a driver here. An initial framing ("defer to campus Intune; the lab shouldn't run
its own MDM") was **reconsidered** once the real driver — lab-owned loaner theft of
unpublished IP, with the lab as the responsible party — was explicit: the lab must
own the control plane.

Device management is a **lab-wide capability**, not E4E-specific: it hangs off
`KRG.LOCAL` AD (ADR 0009/0010), Authentik SSO, and `base.nix`. E4E owns the first
devices but is a **tenant** (ADR 0005, ADR 0008), and **KRG admins currently hold
admin on E4E devices** (no access-isolation today — accepted for now, see
Consequences).

## Decision

- **The lab owns the endpoint control plane.** It enforces device config and can
  lock/wipe a stolen device itself, rather than deferring control to campus Intune.
- **FDE-first.** Full-disk encryption with a **boot secret** (BitLocker / FileVault /
  LUKS) is the load-bearing theft defense on every platform — **not** bare TPM
  auto-unlock (a powered-on stolen laptop would already be decrypted). **Remote wipe
  is an opportunistic secondary** that only lands if the device reconnects.
- **Two git-declarative control planes, split by platform:**
  - **Fleet** (self-hosted, a krg-prod compose stack alongside Authentik/Grafana) —
    the **MDM-capable** platforms: macOS, Windows, iOS/iPadOS, Android. Provides FDE
    key **escrow** (BitLocker/FileVault recovery keys held by the lab), **remote
    lock/wipe**, **OS/app update** push, config profiles, and the macOS **Kerberos
    SSO Extension** profile (realm `KRG.LOCAL`) — **not** legacy AD directory binding.
    Driven declaratively via `fleetctl gitops`.
  - **The flake** — **NixOS**: LUKS FDE, config, and updates via the existing
    `krg.base` `system.autoUpgrade` mechanism (git → `main` → 04:00 pull). A new
    `profiles/laptop.nix` carries the roaming deltas (re-enable suspend — `base.nix`
    forbids it fleet-wide; local home, not NFS `/home`).
- **Lives in `krg-infra`** as lab-wide capability + E4E-scoped tenant config, **not a
  separate repo** (per ADR 0005 / ADR 0008). If cross-repo reuse is ever needed, the
  mechanism is a **flake input**, not a git submodule.

## Consequences

- **NixOS cannot be remote-wiped by any MDM** (no Linux MDM protocol) — FDE is its
  entire theft defense. Accepted gap: do not lend NixOS for work that requires a
  remote-wipe guarantee.
- **Apple Watch is unmanageable** by any MDM (governed only via its paired iPhone).
- **Intune coordination:** a loaner that touches the trusted campus net must still
  enroll in Intune → **dual management** on that subset. Do **not** also run the
  `oec_qualys_trellix` role on Intune-managed laptops — Intune delivers Qualys/Trellix
  there (the laptop analogue of ADR 0006). The OEC role stays scoped to NixOS servers,
  Proxmox hosts, and the Synology appliance.
- **New artifacts:** a krg-prod Fleet compose stack (Traefik + Authentik SSO), a
  `fleetctl gitops` config layer (E4E-scoped teams/policies/profiles), and
  `profiles/laptop.nix`. Fleet MDM bring-up (APNs cert + Apple Business Manager for
  Apple; Android Enterprise; Fleet's own WSTEP for Windows) is documented as the
  appliance-style break-glass exception, with everything else declarative.
- **Roaming SLA:** loaners converge "on next wake/connect," not on a fixed schedule —
  wider drift than always-on servers; both planes are deliver-on-next-checkin. The CI
  gate on `main` is the safety net (NixOS only auto-switches configs that built green).
- **Access model — revisit trigger:** KRG admins currently hold admin on E4E devices;
  there is **no access-isolation between KRG and E4E** today. This is accepted **for
  now**, not asserted as permanent. If E4E later becomes an access-isolated trust
  domain, revisit the repo boundary (split via flake input, not submodule) and this ADR.
