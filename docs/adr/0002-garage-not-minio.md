# 0002. Garage for S3 object storage (not MinIO / RustFS / SeaweedFS)

**Status:** Accepted · **Date:** 2026-05-22

## Context

krg-prod needs S3-compatible object storage (FishCamera / ML data, artifact stores).
The work is Navy/NOAA-adjacent, so **provenance and maintenance health matter**.

## Decision

Use **Garage**.

- **Not MinIO:** the MinIO repository was archived (Feb 2026, again Apr 2026) and is
  officially unmaintained; Synology is steering users toward proprietary AIStor.
  Not viable for a new deployment.
- **Not RustFS:** still beta as of mid-2026 — months of track record vs. Garage's
  years — and provenance matters here. Reconsider in 12+ months if it stabilizes.
- **Not SeaweedFS:** more capable than we need; revisit only if workloads grow into
  hundreds of millions of small objects.
- **Garage:** mature, self-hostable, right-sized, **AGPLv3** (fine for internal use —
  we are not redistributing modifications).

## Consequences

- AGPLv3 obligations apply only if we distribute modified Garage; we don't.
- Image version is **pinned**, never `latest` (DSM Container Manager).
- Buckets/keys/policies/quotas are declared in `spec/e4e-nas/garage.yml` and applied
  by the `garage_config` Ansible role; drift read back via `garage … -o json`.

Related: ADR 0003 (where Garage runs).
