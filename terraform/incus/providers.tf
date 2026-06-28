# terraform/incus — the IaC BOUNDARY of the Incus platform (ADR 0017 §3).
#
# Counterpart to the `krg.incus` nix module (nix/modules/incus.nix): nix stands the
# Incus DAEMON up (the substrate — "this host runs Incus + exposes its API"); THIS
# root module shapes TENANCY on top — the managed NAT network, per-tenant projects +
# quotas, the baseline profile, and (image-gated) instances. Reconciled by `tofu
# plan` exactly as terraform/openbao reconciles OpenBao. The split is what makes "git
# is truth" hold on the boundary (ADR 0001) and maps 1:1 onto the provision-vs-manage
# line (ADR 0017 §2, ADR 0020): admin owns the boundary here; the owning team manages
# the interior via repo-owns-deploy (§8).
#
# AUTH — krg-deploy authenticates to the krg-nat API with a CLIENT CERTIFICATE trusted
# by the server (added ONCE at bring-up: `incus config trust add` on krg-nat → a trust
# token → `incus remote add krg-nat <token>` on krg-deploy, which mints + stores the
# client cert under the incus config dir). The provider then reads that cert on every
# run. The API itself is ucsd+ops-restricted at the firewall (the nix module) and
# OIDC-gated for humans; this cert is the machine identity. See the README.

terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 0.3"
    }
  }
  required_version = ">= 1.11.0"
}

provider "incus" {
  # config_dir defaults to the operator's ~/.config/incus (krg-deploy's), where the
  # bring-up trust flow stored the client cert + the krg-nat remote. Pinned here only
  # if a non-default location is needed.

  remote {
    name    = "krg-nat"
    address = var.incus_api_address
    default = true
  }
}
