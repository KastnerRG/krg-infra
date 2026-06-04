# OpenTofu / provider pinning for the e4e-nas (Synology DSM) layer.
#
# Use OpenTofu (`tofu`), not HashiCorp Terraform: it is FOSS, in nixpkgs
# (`nix run nixpkgs#opentofu`), and supports native state encryption — which
# matters here because the state file will contain DSM credentials and we are
# pre-Vault.
terraform {
  # 1.7+ for the `encryption` block (state encryption).
  required_version = ">= 1.7.0"

  required_providers {
    synology = {
      source  = "synology-community/synology"
      version = "~> 0.6"
    }
  }

  # --- State (local for now; "start local and we'll migrate it") ---------
  # No backend block => local `terraform.tfstate` (gitignored, see .gitignore).
  # When we migrate, add a `backend` block here and `tofu init -migrate-state`.
  #
  # State holds DSM secrets. To encrypt it at rest, supply the encryption
  # config out-of-band via the TF_ENCRYPTION environment variable (so no
  # passphrase lives in the repo) rather than a hardcoded `encryption {}`
  # block — see terraform/README.md "State encryption". The encryption block
  # cannot read input variables, which is why we keep it out of the HCL.
}
