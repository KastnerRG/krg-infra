variable "incus_api_address" {
  description = "https URL of the krg-nat Incus API (ucsd+ops-restricted at the firewall)."
  type        = string
  default     = "https://krg-nat.ucsd.edu:8443"
}

variable "incus_config_dir" {
  description = <<-EOT
    Directory the provider reads its client cert (client.crt/client.key) from.
    deploy-tofu.sh populates an EPHEMERAL dir per apply with a PKI-minted cert and sets
    TF_VAR_incus_config_dir to it — so the provider never depends on a user's
    ~/.config/incus (that reliance was the drift this replaces). Empty falls back to the
    provider default; that fallback must NOT be relied on in the deploy.
  EOT
  type        = string
  default     = ""
}

variable "nat_network_name" {
  description = "Name of the managed internal NAT bridge (the nix preseed leaves this to terraform)."
  type        = string
  default     = "incusbr0"
}

variable "nat_ipv4_subnet" {
  description = <<-EOT
    Gateway address + CIDR of the internal tenant NAT. Incus runs DHCP + DNS on it
    and SNATs egress (ipv4.nat) — "egress NAT is the Incus managed network" (ADR 0017
    §5). RFC1918; instances get addresses here. The zone edges reach instances by the
    ingress path settled at bring-up (route / proxy / shared bridge — see the krg-nat
    host config).
  EOT
  type        = string
  default     = "10.100.0.1/24"
}

variable "storage_pool" {
  description = "Bootstrap storage pool name created by the krg.incus nix preseed (the `dir` pool on /var/lib/incus)."
  type        = string
  default     = "default"
}

variable "tenants" {
  description = <<-EOT
    The BOUNDARY per student-project tenant: an Incus project + resource quota, plus
    an (image-gated) instance launched from the hardened golden template. MIRRORS the
    OpenBao tenant roster (terraform/openbao/tenants.tf) and the nix tenant intent —
    the same three known tenants (fishsense, smartfin, roster) the platform is built
    for; kept a tofu var here since the layers consume it differently (a shared source
    could dedupe later).

    Fields:
      zone      — which public edge routes to it: "krg" (krg-prod) | "e4e" (e4e-prod).
      cpu/memory/disk — the project quota (limits.*), so one tenant can't starve prod.
      isolation — "virtual-machine" (default) for semi-trusted DEVELOPED code, per ADR
                  0017 §4 (containers are reserved for admin-operated/trusted instances;
                  untrusted/self-serve always get a separate kernel).
      image     — the golden-template image to launch the slot from. Empty (the default)
                  = BOUNDARY ONLY (project + quota, no instance) until the hardened
                  template image lands (ADR 0017 §7). Set it to materialize the slot.
  EOT
  type = map(object({
    zone      = string
    cpu       = optional(number, 2)
    memory    = optional(string, "4GiB")
    disk      = optional(string, "20GiB")
    isolation = optional(string, "virtual-machine")
    image     = optional(string, "")
  }))
  default = {}

  validation {
    condition     = alltrue([for t in var.tenants : contains(["krg", "e4e"], t.zone)])
    error_message = "Each tenant.zone must be \"krg\" or \"e4e\" (selects the public edge)."
  }

  validation {
    condition     = alltrue([for t in var.tenants : contains(["virtual-machine", "container"], t.isolation)])
    error_message = "Each tenant.isolation must be \"virtual-machine\" or \"container\" (ADR 0017 §4: untrusted = VM)."
  }
}
