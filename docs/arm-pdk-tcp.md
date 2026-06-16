# ARM PDK technology control plan — RDP access gate on waiter

The ARM Process Design Kit (PDK) is licensed/controlled IP. The technology control
plan (TCP) requires that the controlled population reach waiter's desktop only over
an **auditable SSH tunnel** (key-based, logged), never via the one-click Guacamole
browser RDP. This documents the technical control that enforces that, what it does
*not* cover, and the on-box step needed before it can be trusted.

## Who is gated

The deny set is **`ARM PDK Access` ∪ everyone who can sudo**:

- `ARM PDK Access` — the AD group for controlled-tooling access. (`Domain Admins` are
  added into this group AD-side, so admins are covered by membership.)
- `krg.adClient.sudoGroups` — every AD group that grants sudo (today `Domain Admins`).
  This is read **live** from the sudo config in Nix, so adding a new sudo group later
  automatically extends the RDP deny — the grant and the block can't drift apart.
- local `wheel` — the only other escalation path NixOS grants sudo through.

This captures "anyone who got sudo without being a Domain Admin." The one thing it
does **not** catch is a per-user `sudoers.d` / `security.sudo.extraRules` grant that is
not backed by a group — the repo's model never does that (sudo is granted by group),
but note it in any audit.

## How it works

Guacamole can't enforce this itself: a Guacamole administrator is a superuser, and a
superuser can launch any connection — there is no per-connection deny. So enforcement
lives at **waiter's xrdp authentication**, where the two access paths are
distinguishable by **RDP source IP**:

| Path | Route to waiter:3389 | Source IP waiter sees | Outcome for the deny set |
|------|----------------------|------------------------|--------------------------|
| Guacamole (clientless) | guacd on krg-prod → waiter:3389 | krg-prod (`krg.firewall.rdpSources`) | **denied** |
| SSH tunnel + RDP | `ssh -L 3389:localhost:3389 waiter` → loopback → waiter:3389 | `127.0.0.1` | **allowed** |

A `pam_access` rule on the `xrdp-sesman` **account** stack denies the gated groups when
the session originates from the gateway source(s); loopback is never in that list, so
the tunnel path is unaffected. Researchers not in the deny set keep clientless RDP.

Implementation: `krg.xrdp.gatewayDeny` in [../nix/modules/desktop/xrdp.nix](../nix/modules/desktop/xrdp.nix),
enabled on waiter in [../nix/hosts/waiter/default.nix](../nix/hosts/waiter/default.nix).
The AD group names are bridged to a fixed-GID, space-free local group
(`armpdk-rdp-deny`) via `krg.adGroupSync` because `pam_access` can't reliably match AD
group names containing spaces (e.g. `Domain Admins`). The gateway source defaults to
`krg.firewall.rdpSources`, so it tracks the firewall instead of being typed twice.

## Validation gate (do this before trusting the control)

The whole control hinges on xrdp passing the client IP to PAM as `PAM_RHOST`. Confirm
it on waiter (read-only discovery):

1. From a deny-set account, connect **via Guacamole** → expect the RDP login to be
   refused. Connect the **same account via SSH tunnel** (`ssh -L 3389:localhost:3389
   waiter`, then RDP to `localhost:3389`) → expect success.
2. From a non-deny-set researcher account, connect via Guacamole → expect success.
3. Cross-check the sesman log (`journalctl -u xrdp-sesman` / `/var/log`) shows the
   client IP and that `pam_access` matched the gateway origin.

If xrdp does **not** populate `PAM_RHOST`, the rule silently no-ops (everything is
permitted). Fallback in that case: bind xrdp to loopback-only and route all RDP —
including Guacamole's — so it can't reach the box except through SSH, dropping the
clientless connection for everyone.

## Caveats (administrative controls cover these)

- **Root on waiter.** The deny set has sudo on waiter, so they could technically edit
  PAM live. `nixos-rebuild` reasserts the rule every deploy, and `krg.adGroupSync`
  re-applies group membership on a 10-min timer, but a determined admin with root is
  not *technically* contained — the control removes the standard, one-click path and
  gives a reproducible, auditable boundary, not a cryptographic wall.
- **Guacamole gateway host.** guacd/Guacamole run on krg-prod. Anyone with root on
  krg-prod can reach the Guacamole DB directly; that's outside this control.

These belong in the TCP's administrative-controls / authorized-persons section.
