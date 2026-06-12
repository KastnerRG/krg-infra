# Remote desktop (GNOME Wayland over RDP)

Compute nodes (waiter-style, FPGA on) expose a **GNOME Wayland** desktop over RDP
via `gnome-remote-desktop` in **system/headless "remote login"** mode: a system
daemon listens on 3389 and hands each connection to its own per-user headless GDM
session — so multiple researchers each get their own desktop (the multi-user model
the old xrdp gave us). Module: `nix/modules/desktop/gnome-remote.nix`
(`krg.remoteDesktop`), enabled by the `compute` profile when FPGA is on.

> **Why not KDE / KRDP, and why not Wayland-on-xrdp:** xrdp is X11-only (can't
> serve Wayland). KDE's native KRDP can't do multi-user — it reuses one shared
> session and needs a logged-in session (no headless). gnome-remote-desktop's
> system mode is the only mature multi-user *Wayland* RDP path on NixOS today.

## Access model: through Guacamole, not direct RDP
Users **never** RDP to a compute box directly. Access is via **Apache Guacamole**
(clientless, browser-based) running on **krg-prod**, behind Traefik + Authentik SSO
— so login is the lab's normal SSO, in a web browser, no RDP client and no VPN
needed. Guacamole proxies the connection to the compute box's RDP.

Accordingly, the compute firewall restricts **3389 to krg-prod only**
(`krg.firewall.rdpSources = ["137.110.161.106"]` in `profiles/compute.nix`):
waiter's RDP is reachable from the Guacamole gateway and nowhere else — not the
public internet, not the VPN, not other campus hosts. The single ingress is the
SSO-gated web app.

> The Guacamole gateway service itself (guacd + webapp + DB + Authentik OIDC, a
> compose stack on krg-prod) is tracked separately — see the deployment notes /
> tracking issue. This module + firewall rule are the compute-side half: a desktop
> that only Guacamole can reach.

Performance: RDP is fine for desktop/IDE work, **laggy for heavy 3D**
(Vivado/Vitis rendering); X11 vs Wayland makes no difference on the wire.

## One-time bring-up (maintenance window) — NEEDS ON-BOX VALIDATION
The NixOS module only exposes `enable`; the TLS cert + `grdctl --system enable`
have no declarative option upstream. The `krg-rdp-bootstrap` systemd oneshot does
this automatically (idempotent, self-healing, non-fatal), but the **exact
`grdctl --system` behaviour can't be verified from a flake eval** — validate it on
the box during the window:

```bash
# 1. After deploy, check the bootstrap ran and RDP is enabled:
systemctl status krg-rdp-bootstrap.service
sudo -u gnome-remote-desktop grdctl --system status      # expect: RDP enabled, TLS cert/key set
systemctl status gnome-remote-desktop.service
ss -tlnp | grep 3389                                       # daemon listening

# 2. Connect (via the SSH tunnel above) as an AD user → you should land on the
#    GDM greeter, authenticate, and get your own GNOME session.
```

**Manual fallback** if the oneshot's invocation needs adjusting (run as the
gnome-remote-desktop user, then re-deploy with the fix folded into the module):

```bash
state=/var/lib/gnome-remote-desktop
sudo -u gnome-remote-desktop openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -subj "/CN=waiter-rdp" -keyout "$state/tls.key" -out "$state/tls.crt"
sudo chmod 600 "$state/tls.key"
sudo -u gnome-remote-desktop grdctl --system rdp set-tls-cert "$state/tls.crt"
sudo -u gnome-remote-desktop grdctl --system rdp set-tls-key  "$state/tls.key"
sudo -u gnome-remote-desktop grdctl --system rdp enable
```

The enable-state + cert live under `/var/lib/gnome-remote-desktop`, which is
persisted across waiter's impermanence rollback, so this is genuinely one-time.

## The desktop is approachable by default — and users can change it
Every user starts in a Windows/KDE-like layout (bottom taskbar via dash-to-panel,
a Start menu via ArcMenu, a system tray, desktop icons), with min/max/close window
buttons and the common apps pinned. These are **soft, unlocked defaults**
(GSettings schema overrides, *not* dconf locks), so any user can change their own:

- **From the GUI:** GNOME Settings / Tweaks / the Extensions app. Changes write the
  user's `~/.config/dconf/user`, which overrides our defaults and **persists in the
  NFS home**.
- **With Home Manager (power users):** standalone HM in your own home overrides our
  defaults declaratively. `enabled-extensions`/`favorite-apps` are whole-list keys,
  so setting your own replaces ours (your preference wins). Sample
  `~/.config/home-manager/home.nix`:

  ```nix
  { config, pkgs, ... }:
  {
    home.username = "you";
    home.homeDirectory = "/home/you";
    home.stateVersion = "26.05";

    dconf.settings = {
      "org/gnome/shell".favorite-apps =
        [ "org.gnome.Console.desktop" "code.desktop" "firefox.desktop" ];
      "org/gnome/desktop/interface".color-scheme = "default";  # light
      # Run vanilla GNOME instead of the lab layout:
      # "org/gnome/shell".enabled-extensions = [ ];
    };

    # Add your own extensions (system-installed ones are already available):
    programs.gnome-shell.extensions = [
      { package = pkgs.gnomeExtensions.blur-my-shell; }
    ];

    programs.home-manager.enable = true;
  }
  ```
  Apply with `nix run home-manager/master -- switch` (nix + flakes are available to
  users). Your config lives in the NFS home, so it persists.

The only thing a user *can't* override is a setting we deliberately lock — and we
lock nothing here, on purpose.
