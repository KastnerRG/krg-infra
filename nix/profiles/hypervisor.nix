# Hypervisor profile: a host whose role is to run guest VMs/containers for the tenant
# platform (ADR 0017). The role leaf for the platform tier — same shape as
# directory.nix (server + a role module): it layers the guest-hosting substrate onto
# the `server` tier (base + monitoring). Import in a host's default.nix, then add
# host-specific networking + disk (and isVM for a nested guest).
#
# WHAT, not how: this profile declares the role; the mechanism — Incus (the daemon,
# the internal-NAT substrate, the API) — lives in modules/incus.nix, and the tenancy it
# serves (NAT network, per-tenant projects/quotas/instances) is the terraform/incus
# boundary (ADR 0017 §3). Portable across the phase-1 nested VM and phase-2 bare metal.
{...}: {
  imports = [
    ./server.nix # base + monitored-infra (node-exporter); break-glass admin via base
    ../modules/incus.nix
  ];

  krg.base = {
    enable = true;
    autoUpgrade = true;
    serviceHost = true; # control-plane host — restrict in-guest SSH to ucsd + ops
  };

  # Run the guest-hosting substrate. The module owns the how (daemon, the ucsd+ops API
  # firewall, bootstrap storage) — no firewall/storage wiring belongs in the profile.
  krg.incus.enable = true;
}
