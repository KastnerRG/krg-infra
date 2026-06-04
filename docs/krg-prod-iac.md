# krg-prod IaC — architecture & NAS standup plan

How the krg-prod IaC (specced separately) maps onto this repo, and the concrete path
to **standing the NAS back up under IaC** — the current focus. Decisions are recorded
as ADRs in [`adr/`](adr/); this is the working map.

`krg-prod` spans two hosts:
- **e4e-nas** — Synology DS3617xs (`broadwell`), DSM 7.3 (storage + Garage S3).
- **krg-prod** — NixOS VM on Proxmox (monitoring stack + supporting services).

Git is the source of truth; UI/by-hand changes are drift (ADR 0001).

## Where each piece lives (integrated, not a parallel repo — ADR 0005)

| Concern | Home | Tool |
|---|---|---|
| VM OS + apps | `nix/` flake, host `krg-prod` (`nixos-rebuild switch --flake ./nix#krg-prod --target-host …`) | NixOS |
| systemd-wraps-compose | `nix/modules/services/compose-stack.nix` (`krg.composeStacks`) | NixOS |
| Monitoring stack | `nix/docker-compose/krg-prod/` (extend: alertmanager, `drift_exporter/`, `prometheus/rules/`, grafana provisioning + JSON dashboards) | compose |
| NAS — provider-covered (shares, Garage container, files) | `terraform/e4e-nas/` (add `backend.tf`, `nas-shares.tf`, `nas-containers.tf`) | OpenTofu |
| NAS — CLI-only (ACLs, NFS, SMB globals, snapshots, SSH, firewall, packages, users/groups) | `ansible/synology/roles/synology_*` + `synology` group (host `e4e-nas`) | Ansible |
| Declarative DSM spec | `spec/e4e-nas/*.yml` (seeded from the build sheet) | data |
| Test rig | new `nix/` flake outputs (`apps.dsm-vm`, `apps.test-pr`) + `nix/test/dsm-rig.nix` | NixOS/libvirt |
| Decisions / break-glass | `docs/adr/`, `docs/e4e-nas-dsm.md` (→ break-glass) | docs |
| Deploy control node + state | `krg-deploy` (runs tofu/ansible/nixos-rebuild; holds encrypted state) | — |

**Invariant:** one host = one config tool. The NAS is Ansible+OpenTofu; the VM is
NixOS only (never in the Ansible inventory).

## Standing the NAS back up: bootstrap vs. IaC

Some of a DSM standup is irreducibly manual (you can't IaC the install wizard). Keep
that minimal and documented as break-glass; everything after is repeatable IaC.

**Bootstrap (manual, break-glass `docs/e4e-nas-dsm.md`):**
1. Mode-2 reset (reinstall DSM, **keep data volumes**). DSM install wizard.
2. Network (static IP `132.239.17.124`, gateway, DNS → KRG.LOCAL DC).
3. Enable SSH + Web API; create the **automation account** (API token) and a
   **break-glass SSH key** admin; disable the built-in `admin`.
4. Join **KRG.LOCAL** (it was on the dead KRG.UCSD.EDU domain).

**IaC (repeatable, from `krg-deploy`):**
5. OpenTofu `terraform/e4e-nas/`: shared folders (`nas-shares.tf`), Garage container
   (`nas-containers.tf`), file provisioning.
6. Ansible `synology_*` roles from `spec/e4e-nas/`: groups → users → shares → ACLs
   (recursive re-apply over the preserved data — old SIDs are dead) → SMB globals →
   NFS exports → firewall → packages → snapshot/scrub schedules.
7. `garage_config` role: buckets/keys/policies from `spec/e4e-nas/garage.yml`.
8. UI lockdown cutover (LAST — only once automation creds + break-glass + audit
   shipping are proven, or you lock yourself out).

## NAS-focused milestone order

0. **Seed `spec/e4e-nas/`** from the build sheet (`docs/e4e-nas-dsm.md`: 55 shares,
   16 groups, service settings → `shares.yml`/`groups.yml`/`smb-globals.yml`/
   `nfs-exports.yml`). Pure data; unblocks every role.
1. **Test rig** (XPEnology **DS3622xs+/`broadwellnk`, DSM 7.3** in libvirt via the RR
   loader) — validate CLI/API/idempotency before prod. Highest-uncertainty, zero
   prod blast radius.
2. **`synology_users` role** (+ exporter) — first idempotent role, proven on the rig.
3. **OpenTofu skeleton + backend + import** existing shares; scaffold the Garage
   container resource.
4. **Garage** (container + `garage_config`).
5. Shares/ACLs/SMB/NFS/firewall roles.
6. Drift detection (exporter + Loki audit path), CI, UI-lockdown cutover.

## Open items

- **Proxmox host:** this repo's `ansible/` already manages it (fabricant) — confirm
  the "separate Ansible IaC" in the spec *is* this layer (then we just reuse its
  `monitoring` role as the node_exporter scrape source), not a third repo.
- **krg-deploy:** to be defined/hardened as a host before it becomes the live control
  node. Until then, state is local.
- **Test-rig fidelity:** DSM-in-KVM validates CLI/API/idempotency, **not** storage
  (SHR/Btrfs on real disks) or fans/sensors — those only surface on the real NAS.
  It also emulates **DS3622xs+ (`broadwellnk`)**, not a literal DS3617xs: the RR
  loader supports `broadwellnk` on DSM 7.3, whereas native `broadwell` (DS3617xs) is
  poorly supported and `bromolow` (DS3615xs, Ivy-Bridge-era) is dropped at 7.3. Fine
  — the DSM CLI surface we test is model-agnostic.
