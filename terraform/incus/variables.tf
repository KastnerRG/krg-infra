variable "incus_api_address" {
  description = <<-EOT
    FQDN/IP of the krg-nat Incus API — a BARE HOST, no scheme and no port. providers.tf
    composes it with incus_api_port into the full `https://host:port` URL the lxc/incus
    1.x remote.address expects. (Kept as a bare host, separate from the port, so the port
    still mirrors the nix krg.incus.apiPort 1:1; the 1.x provider is what joins them.)
    (ucsd+ops-restricted at the firewall.)
  EOT
  type        = string
  default     = "krg-nat.ucsd.edu"
}

variable "incus_api_port" {
  description = "Port of the krg-nat Incus API (remote.port). Mirrors the nix krg.incus.apiPort."
  type        = string
  default     = "8443"
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
    §5). RFC1918; instances get addresses here. Zone edges reach instances via a proxy
    device on krg-nat (instances.tf), NOT an L3 route into this subnet (Incus masquerades
    the return path — validated on-box).
  EOT
  type        = string
  default     = "10.100.0.1/24"
}

variable "storage_pool" {
  description = "Bootstrap storage pool name created by the krg.incus nix preseed (the `dir` pool on /var/lib/incus)."
  type        = string
  default     = "default"
}

variable "incus_host_ip" {
  description = <<-EOT
    krg-nat's own uplink IP — the listen address of the tenant INGRESS network forwards
    (edge → instance, forwards.tf). The zone edge (e4e-prod / krg-prod) dials
    `incus_host_ip:<edge_port>` on its OWN segment (no route needed); an incus_network_forward
    on this IP DNATs to the instance's pinned nat_ip:443. This is the settled ingress
    mechanism (ADR 0017 §5): a network forward (pure host-side DNAT, the ports opened in
    krg.incus.tenantIngressPortRange), NOT an L3 route into the NAT (Incus masquerades the
    return path) nor a proxy device (VM instances support proxy nat-mode only) — both
    validated on-box. Proxmox-independent. Defaults to krg-nat's address in
    nix/networks/trusted.json.
  EOT
  type        = string
  default     = "137.110.161.105"
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
      nat_ip    — a PINNED address on the internal NAT (e.g. "10.100.0.10") for this
                  instance, so the ingress forward has a STABLE target (a DHCP lease could
                  move on reprovision). REQUIRED to expose the tenant (edge_port needs it).
                  Must be inside nat_ipv4_subnet (10.100.0.0/24) and unique across tenants.
      edge_port — the port on `incus_host_ip` (krg-nat) the zone edge dials to reach this
                  instance. 0 (default) = NOT publicly exposed (boundary only). When >0, an
                  incus_network_forward (forwards.tf) DNATs incus_host_ip:<edge_port> →
                  nat_ip:443 (the instance's inner Traefik), and the edge route's `backend`
                  is "<incus_host_ip>:<edge_port>" (ADR 0017 §5). Allocate a distinct port
                  per exposed tenant within the reserved range krg.incus opens (default
                  30000-30999); they share krg-nat's one IP. (A network forward — not a
                  proxy device — because a proxy on a VM supports nat mode only; validated
                  on-box.)
      repo      — the tenant's GitHub repo "owner/name" (e.g. "UCSD-E4E/fishsense-lite").
                  Stamped onto the instance as `user.krg_repo` so the provision leg
                  (deploy/stage-tenant-secret-zero.sh) brokers + pushes a runner
                  registration token, and nixosModules.tenant runs a runner scoped to it
                  (repo-owns-deploy, ADR 0022). Empty (default) = no runner provisioned.
  EOT
  type = map(object({
    zone      = string
    cpu       = optional(number, 2)
    memory    = optional(string, "4GiB")
    disk      = optional(string, "20GiB")
    isolation = optional(string, "virtual-machine")
    image     = optional(string, "")
    nat_ip    = optional(string, "")
    edge_port = optional(number, 0)
    repo      = optional(string, "")
  }))

  # fishsense — tenant #1 (docs/onboarding-fishsense.md §2b). This is exactly
  # `nix eval .#krgTenant.terraformTenant --json` from the fishsense-lite flake
  # (zone/cpu/memory/disk/isolation/image — the mkTenant spec→provision projection),
  # PLUS the three admin-allocated fields: `image` (the published golden template,
  # gate 3 DONE), `nat_ip` (a pinned NAT address for the ingress forward's target), and
  # `edge_port` (a free port in the reserved 30000-30999 range the e4e-prod edge dials).
  # The tenant cannot self-grant any — an admin lands them here (ADR 0020 §3).
  default = {
    fishsense = {
      zone      = "e4e"                     # fronted by the e4e-prod edge (*.e4e.ucsd.edu)
      cpu       = 6                         # resources.cpu from mkTenant
      memory    = "12GiB"                   # resources.ram (renamed to the Incus field)
      disk      = "50GiB"                   # Postgres + Superset images/volumes; dir-pool root size IS the cap
      isolation = "virtual-machine"         # untrusted developed code = separate kernel (§4)
      image     = "krg-golden"              # boot the slot from the hardened template
      nat_ip    = "10.100.0.10"             # pinned NAT target for the ingress forward
      edge_port = 30443                     # krg-nat port the e4e edge dials → network forward → nat_ip:443
      repo      = "UCSD-E4E/fishsense-lite" # repo-owns-deploy runner scope (ADR 0022)
    }
  }

  validation {
    condition     = alltrue([for t in var.tenants : contains(["krg", "e4e"], t.zone)])
    error_message = "Each tenant.zone must be \"krg\" or \"e4e\" (selects the public edge)."
  }

  validation {
    condition     = alltrue([for t in var.tenants : contains(["virtual-machine", "container"], t.isolation)])
    error_message = "Each tenant.isolation must be \"virtual-machine\" or \"container\" (ADR 0017 §4: untrusted = VM)."
  }

  # A publicly-exposed tenant (edge_port > 0) needs an instance to DNAT to — so image must
  # be set (no instance = nothing for the forward to target).
  validation {
    condition     = alltrue([for t in var.tenants : t.edge_port == 0 || t.image != ""])
    error_message = "A tenant with edge_port > 0 must also set image (the ingress forward needs an instance to target)."
  }

  # A publicly-exposed tenant also needs a pinned nat_ip — the ingress forward's DNAT target
  # (forwards.tf). Without it the forward would have no stable destination.
  validation {
    condition     = alltrue([for t in var.tenants : t.edge_port == 0 || t.nat_ip != ""])
    error_message = "A tenant with edge_port > 0 must also set nat_ip (the ingress forward's DNAT target)."
  }

  # nat_ip, when set, must be a host in the tenant NAT subnet (10.100.0.2-254; .0 network,
  # .1 gateway, .255 broadcast excluded) — the address the instance NIC is pinned to and the
  # forward targets. Mirrors nat_ipv4_subnet (10.100.0.1/24).
  validation {
    condition = alltrue([
      for t in var.tenants : t.nat_ip == "" || (
        can(regex("^10\\.100\\.0\\.[0-9]{1,3}$", t.nat_ip)) &&
        tonumber(split(".", t.nat_ip)[3]) >= 2 &&
        tonumber(split(".", t.nat_ip)[3]) <= 254
      )
    ])
    error_message = "Each tenant.nat_ip must be a host address in 10.100.0.2-254 (the tenant NAT subnet, nat_ipv4_subnet)."
  }

  # edge_ports must fall inside the range krg.incus opens in the firewall (default
  # 30000-30999) and be unique across tenants (they share krg-nat's one IP).
  validation {
    condition     = alltrue([for t in var.tenants : t.edge_port == 0 || (t.edge_port >= 30000 && t.edge_port <= 30999)])
    error_message = "Each tenant.edge_port must be within the reserved ingress range 30000-30999 (krg.incus.tenantIngressPortRange)."
  }
}
