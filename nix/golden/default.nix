# nix/golden/default.nix — the KRG Incus GOLDEN TEMPLATE (ADR 0017 §7, gate 3).
#
# The single, shared, app-agnostic, HARDENED NixOS system that every tenant instance
# boots from. It is built into an Incus VM IMAGE — `system.build.qemuImage` (a
# qcow2-compressed disk) + `system.build.metadata` (the Incus image-metadata tarball),
# both from the incus-virtual-machine.nix module below — and published to krg-nat's
# image store under the alias `krg-golden` by deploy/incus-publish-golden.sh.
# terraform/incus then launches a tenant slot from it (var.tenants.<t>.image =
# "krg-golden"); the tenant's OWN flake converges the instance to its full config via
# repo-owns-deploy (ADR 0017 §8, ADR 0020). TTL-reap destroys and relaunches from this
# same image, so "rebuilt from the golden template" is literal.
#
# WHY ONE SHARED BASE (not a per-tenant baked image): matches the ADRs' "the golden
# template" / "one fleet-wide image set", is one artifact to maintain, and serves both
# NixOS-instance tenants (fishsense — converge via its flake) and compose tenants alike.
#
# §7 "born from the hardened template" — the required properties and where each lives:
#   • AD-join            — krg.adClient (base.nix), baked-but-gated on the keytab; the
#                          actual domain join is per-instance at provisioning (#391 keeps
#                          an unjoined host from failing), so the image bakes the config,
#                          not a machine secret.
#   • key-only SSH       — services.openssh hardening (base.nix).
#   • auto-upgrade       — system.autoUpgrade (base.nix), targeting #krg-golden here.
#   • monitoring         — node-exporter (profiles/server.nix).
#   • in-guest firewall  — krg.firewall / nftables (base.nix), on inside the VM too.
#   • central logging    — DEFERRED. The shipper + write-only push identity belong here
#                          (ADR 0015 part E / §7), but the Loki mTLS push endpoint
#                          (ADR 0015-C) isn't built yet. This is the one remaining §7
#                          item; wire the shipper when the fan-in lands (tracked below).
#
# MINUS OEC — "OEC follows PERSISTENCE, not location" (§7). This is the EPHEMERAL tier,
# OEC-exempt, compensated by enforced TTL + rebuild-from-golden + auto-patch +
# segmentation + central logging. A tenant that CONVERTS to a persistent instance
# re-enables OEC from its own flake (base.nix turns it on for every normal host).
{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    # Turns this system into an Incus VM image and adds the VM-guest plumbing:
    # system.build.qemuImage (qcow2) + system.build.metadata (image metadata tarball),
    # the incus-agent (so Incus can manage the guest), serial console, systemd-boot and
    # growPartition. It also declares the root/ESP fileSystems + bootloader for the
    # image, so — unlike a real host — the golden template needs NO
    # hardware-configuration.nix / disko layout.
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")

    # The §7 lab baseline: base.nix (AD-join, key-only SSH, autoUpgrade, CrowdSec +
    # bouncer, in-guest firewall, break-glass admin) + node-exporter monitoring.
    ../profiles/server.nix
  ];

  # Enable the baseline. isVM = true: this IS an Incus VM-type instance (the
  # untrusted/self-serve isolation tier — separate kernel, ADR 0017 §4).
  krg.base = {
    enable = true;
    isVM = true;

    # The instance lives entirely behind the Incus managed NAT (RFC1918, not the
    # flat-public sealab segment), so the "public workstation needs strict SSH"
    # rationale (base.nix) doesn't apply: the NAT + the zone edge ARE the perimeter,
    # and admin convergence (nixos-rebuild --target-host) reaches it FROM inside the
    # NAT — a source that never matches the ucsd/ops CIDRs strict SSH allows. Leaving
    # it strict would black-hole convergence; open-behind-NAT (+ CrowdSec) is correct
    # here. Revisit once the edge ingress / convergence path is settled (krg-nat host).
    serviceHost = lib.mkDefault false;
  };

  # OEC OFF — ephemeral tier (see header). base.nix enables it unconditionally (hard
  # `true`, not mkDefault), so force it off; conversion to persistent re-enables it.
  krg.oecQualysTrellix.enable = lib.mkForce false;

  # DHCP from the Incus managed NAT — the platform assigns the RFC1918 lease
  # (terraform/incus incus_network.nat). Mirrors nixosModules.tenant.
  networking.useDHCP = lib.mkDefault true;

  # A neutral pre-convergence identity: an instance boots as "krg-golden" until the
  # tenant's flake sets its own hostname on first convergence — the name doubles as a
  # signal that a box hasn't been converged yet. base.nix's autoUpgrade targets
  # #${hostName} = #krg-golden, which resolves to THIS config (self-consistent) until
  # conversion re-points it at the tenant repo.
  networking.hostName = lib.mkDefault "krg-golden";

  system.stateVersion = lib.mkDefault "25.11";
}
