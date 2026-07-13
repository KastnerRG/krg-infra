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
# AUTH — fully declarative, no hand-configured remote (same mTLS-over-fleet-PKI model
# as terraform/temporal). deploy-tofu.sh mints a short-lived CLIENT cert from OpenBao
# (pki_int/issue/incus-client) each apply and writes client.crt/client.key into an
# EPHEMERAL config dir (TF_VAR_incus_config_dir) — nothing in a user's ~/.config.
# krg-nat trusts that cert because its cert chains to the fleet CA, which the krg.incus
# nix module installs as Incus's server.ca with core.trust_ca_certificates=true — so
# there is NO per-cert `incus config trust add`. `accept_remote_certificate` trusts
# krg-nat's server cert on the trusted internal segment. The API is ucsd+ops-restricted
# at the firewall (nix module) and OIDC-gated for humans; this cert is the machine
# identity. See the README.

terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.0"
    }
  }
  required_version = ">= 1.11.0"
}

provider "incus" {
  # The ephemeral config dir deploy-tofu.sh populates with the PKI-minted client cert
  # (client.crt/client.key). Explicit so the provider never depends on the runner's
  # $HOME/.config/incus (that reliance was the drift this replaces).
  config_dir = var.incus_config_dir

  # Trust krg-nat's (self-signed) server certificate — no interactive TOFU. Safe on the
  # trusted internal segment; the client-auth trust is the load-bearing direction and
  # is anchored to the fleet CA (server.ca) on krg-nat.
  accept_remote_certificate = true

  # The remote used when a resource doesn't name one. In lxc/incus 1.x this moved to a
  # provider-level `default_remote` (the per-remote `default = true` of 0.x was removed
  # when the provider config was reworked).
  default_remote = "krg-nat"

  # lxc/incus 1.x reworked the remote schema: `address` is now a FULL URL
  # (`scheme://host:port`) — the separate `scheme`/`port` fields of the 0.x provider are
  # gone. This INVERTS the old 0.x gotcha (where a full URL silently fell back to the unix
  # socket and passing a bare host was required); on 1.x the bare host is what fails, so we
  # build the URL from the mirrored host+port vars here. See variables.tf.
  remote {
    name    = "krg-nat"
    address = "https://${var.incus_api_address}:${var.incus_api_port}"
  }
}
