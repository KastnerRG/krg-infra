# KRG platform tenant

A skeleton tenant repo for the KRG Incus platform ([ADR 0017](https://github.com/KastnerRG/krg-infra/blob/main/docs/adr/0017-incus-nat-self-serve-platform.md) / [ADR 0020](https://github.com/KastnerRG/krg-infra/blob/main/docs/adr/0020-tenant-deploy-contract-mktenant.md)). Initialize it with:

```sh
nix flake init -t github:KastnerRG/krg-infra?dir=nix#tenant
```

## What you own vs what an admin provisions

`flake.nix` makes one `krg-infra.lib.mkTenant` call. Its fields encode the trust split:

- **Interior — yours, authoritative:** `compose` (and image / deploy cadence). Shipped by
  your runner on merged `auto-deploy/*` PRs. Edit `deploy/compose.yml` freely.
- **Boundary — requests, admin-provisioned:** `hostname`/CNAME, `zone`/route, `sso.group`,
  `resources`/quota, the Incus slot. You **request** these; an admin grants them via
  `terraform/incus`. You cannot self-grant a route or quota (that's the point — ADR 0017
  rejected self-serve *services*).

## Onboarding

1. Edit the `mkTenant` call + `deploy/compose.yml`, open a PR in your repo.
2. Open an onboarding PR against `krg-infra` (or hand the admin your spec). The admin copies
   your projection into `terraform/incus`:
   ```sh
   nix eval .#krgTenant.terraformTenant --json
   ```
   and files the CNAME. That `tofu apply` creates your project + quota + slot.
3. Your runner deploys your interior into the slot.

## Pin = contract

`inputs.krg-infra.url` is pinned to a rev — that rev **is** your stable contract. Bump it
deliberately to pick up deploy-contract changes; the surface is narrow and secret-free, so
the bump never drags in lab host configs.

## Staying patched

Bumping that pin is also how your **system** packages (kernel, `bash`, `openssl`, …) update —
NixOS rebuilds atomically from the new `nixpkgs`, there's no `apt`. `.github/workflows/update-flake.yml`
opens a weekly PR that does the bump for you; merge it and the nightly auto-upgrade rolls it out
(reboot for a new kernel). Full model: [`docs/tenant-updates.md`](../../../docs/tenant-updates.md).
