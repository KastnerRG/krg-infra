# KRG NixOS Flakes

NixOS flake-based infrastructure for the KastnerRG / E4E lab, replacing the older
Ansible setups ([waiter](https://github.com/KastnerRG/waiter),
[fabricant-prod](https://github.com/KastnerRG/fabricant-prod)). Hosts are built by
composing profile modules — no per-host playbooks.

See [CLAUDE.md](CLAUDE.md) for the full architecture (modules, profiles, hosts).

## Hosts

| Host         | Profile     | Role                                                       |
|--------------|-------------|------------------------------------------------------------|
| `krg-prod`   | `server`    | KRG lab-wide production (Traefik, Authentik, Grafana, MLflow…) |
| `e4e-prod`   | `server`    | E4E project-specific services (scaffold; FishSense etc.)   |
| `waiter`     | `compute`   | GPU/FPGA research box (CUDA, Vivado, XRDP)                  |
| `krg-ldap`   | `directory` | Samba AD domain controller                                 |
| `krg-vault`  | `base`      | OpenBao secrets manager                                    |
| `krg-deploy` | `base`      | Ansible control node + OpenTofu (drives the `ansible/` + `terraform/` layers) |

## Prerequisites

- A NixOS host with flakes enabled (`experimental-features = nix-command flakes`).
- Your **ed25519** SSH public key in `keys/admins.json` (the shared key file read
  by `users/admin.nix` and the Ansible layer). SSH is key-only and **ed25519-only**
  — RSA keys and passwords are rejected, and root login is disabled.

## Build & validate (no deploy)

```bash
nix flake check                                # nix syntax + module type-check
nixos-rebuild build --flake .#krg-ldap         # build a host's system closure
nix eval .#nixosConfigurations.krg-ldap.config.networking.hostName
```

## Deploy

`nixos-rebuild` is the new "ng" (Python) build, so remote deploys use
`--sudo` / `--ask-sudo-password` (not the old `--use-remote-sudo`).

**On the box itself:**
```bash
sudo nixos-rebuild switch --flake .#<host>
```

**Remotely, from a checkout of this repo:**
```bash
nixos-rebuild switch --flake .#<host> \
  --target-host <admin>@<host-fqdn> --sudo --ask-sudo-password
```

**On a freshly-cloned box:**
```bash
git clone https://github.com/KastnerRG/krg-infra.git
cd krg-infra/nix
sudo nixos-rebuild switch --flake .#<host>
```

> ⚠️ The first switch turns on ed25519-only / key-only SSH. Keep a console open
> (e.g. the Proxmox console) and confirm a fresh SSH session works with your
> ed25519 key before relying on it. Use `nixos-rebuild test` first if unsure —
> it activates without making it the boot default, so a reboot reverts.

## Adding a new host

1. On the target: `nixos-generate-config --show-hardware-config` →
   save as `hosts/<name>/hardware-configuration.nix`.
2. Create `hosts/<name>/default.nix` importing a profile
   (`profiles/{server,compute,directory}.nix`) + the hardware config; set
   `networking`, `krg.adminAccount`, and `system.stateVersion`.
3. Add `<name> = mkSystem "<name>";` to `flake.nix`.
4. `git add` the new files (a flake only sees git-tracked/staged files),
   `nix flake check`, then deploy.

## Security agents (Qualys + Trellix)

Every host runs the campus-mandated Qualys Cloud Agent + Trellix HX (`xagt`) via
`modules/security/oec-qualys-trellix.nix`. The proprietary installer archive is
**not** in git (it contains live enrollment credentials). To enroll a host, place
the archive at the runtime path and let the one-shot installer run:

```bash
# obtain oec-qualystrellixinstallers-linux.tgz from lab storage (gitignored)
scp oec-qualystrellixinstallers-linux.tgz <admin>@<host>:/tmp/
ssh <admin>@<host> 'sudo install -m600 -o root -g root \
    /tmp/oec-qualystrellixinstallers-linux.tgz /var/lib/krg/oec/ \
  && rm /tmp/oec-qualystrellixinstallers-linux.tgz'

# install + enroll (runs once; also fires automatically on next boot)
ssh <admin>@<host> 'sudo systemctl start oec-install'

# verify both daemons are up
ssh <admin>@<host> 'systemctl status xagt qualys-cloud-agent'
```

The agents are unpatched Ubuntu binaries run under `nix-ld` + `envfs`. To force a
reinstall, remove the sentinel: `sudo rm /var/lib/krg/oec/.installed` and rebuild.

## Common commands

```bash
nix flake update                      # update all inputs
nix flake update nixpkgs              # update a single input
alejandra .                           # format all .nix files
nixos-rebuild list-generations        # (on a host) list/rollback generations
```
