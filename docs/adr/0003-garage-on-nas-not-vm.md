# 0003. Garage runs on the NAS, not the krg-prod VM

**Status:** Accepted · **Date:** 2026-05-22

## Context

Garage (ADR 0002) needs to live somewhere. The two candidates are the krg-prod
NixOS VM and the Synology e4e-nas. The Proxmox host's storage is **shared between
the VM's virtual disk and the NFS home directories serving a GPU server** — so the
VM operates under a disk-IO budget (ADR 0004), and object-storage IO would compete
with latency-sensitive interactive workloads on the GPU server. The NAS has
**dedicated storage capacity** for this.

## Decision

Garage runs **on the NAS**, in DSM Container Manager, declared via the OpenTofu
`synology` provider's container resource. Its data lives in a dedicated **`s3-data`
shared folder on Btrfs with a snapshot policy**, bind-mounted into the container.
Garage sits behind DSM's reverse proxy with Let's Encrypt.

This **reverses the earlier "nothing runs on the NAS" stance** — the NAS now runs
**exactly one** workload, and it is itself a *storage service*, which is a narrow,
defensible exception for a storage appliance.

## Consequences

- The NAS is no longer pure-passive storage; it runs (only) Garage. Container
  Manager must be installed/managed.
- Garage's bucket data is **new** data — its criticality is a separate question from
  the existing research shares (which the PI has risk-accepted). The `s3-data` Btrfs
  snapshot policy is its protection; revisit if a bucket holds something that *would*
  be catastrophic to lose.
- Garage availability becomes a monitored, alerted concern (it's on the same box as
  the bulk shares).

Related: ADR 0002, ADR 0004.
