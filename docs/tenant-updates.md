# Keeping a tenant up to date (system packages, kernel, security)

How a KRG Incus tenant (e.g. `UCSD-E4E/fishsense-lite`) gets updates to **system**
packages — the kernel, `bash`, `glibc`, `openssl`, `openssh`, everything below your
containers. (Your *app* code ships in your container images; this doc is the layer
underneath.)

## The model: NixOS, not `apt`

There is no per-package upgrade and no `apt upgrade`. Every system package comes from a
single pinned **`nixpkgs`**. "Update `bash`" means: move the `nixpkgs` pin forward and
**atomically rebuild the whole system** into a new *generation*. If a rebuild is bad you
roll back to the previous generation — nothing is upgraded in place.

So keeping current is two **independent** things, and you need both:

| Axis | Question | Who/what does it |
|---|---|---|
| **A. Apply** | rebuild the instance from your repo's latest `main` | automatic (below) |
| **B. Advance** | move the `nixpkgs` pin so there's something new to apply | **you** (a flake bump) |

Axis A is wired for you. **Axis B is the one you own** — without it, A just rebuilds the
same frozen packages forever.

## Where your packages are pinned

Your `flake.nix` sets `nixpkgs.follows = "krg-infra/nixpkgs"` and pins `krg-infra` at a
rev. So your kernel/`bash`/CVE-relevant libs are **whatever `nixpkgs` the pinned krg-infra
rev carries**, frozen in your `flake.lock`. Advancing = bumping that pin (Axis B).

## Axis A — applying (automatic)

Two paths converge your instance from `github:<owner>/<repo>#<name>`, both build from your
**committed `flake.lock`**:

1. **Nightly auto-upgrade** — `system.autoUpgrade` at **04:00** runs
   `nixos-rebuild switch --refresh --flake github:<owner>/<repo>#<name>`. It targets *your*
   flake (the platform sets `krg.base.flakeUrl` to your repo — a tenant whose upgrade
   pointed at krg-infra's flake would fail silently every night). So anything merged to your
   `main` — including a merged Axis-B bump — rolls out that night, no action needed.
2. **On-merge** — a merged `auto-deploy/**` PR triggers your runner's `<name>-selfupdate`
   unit (same command). Use this to apply immediately instead of waiting for 04:00.

**Kernel note:** auto-upgrade runs with `allowReboot = false` (fleet policy). A new kernel is
built into the new generation but the **running kernel stays until you reboot** the instance:
```bash
incus restart <name> --project <name>
```
Schedule a reboot window if a kernel CVE matters; user-space packages (`bash`, `openssl`,
libraries) take effect on the rebuild without a reboot (services restart as needed).

## Axis B — advancing the pin (**you own this**)

Nothing moves your `nixpkgs` for you. `--refresh` re-fetches your repo but still uses the
`flake.lock` in it. To pull new packages you bump the `krg-infra` input, which drags in its
newer `nixpkgs` via the `follows`:

```bash
nix flake update krg-infra   # updates the krg-infra input → new nixpkgs
git commit -am "chore(flake): bump krg-infra pin"
git push                     # open a PR; merge it
```

Merge it → Axis A applies it (that night, or immediately via an `auto-deploy/**` push).

### Automate it — the weekly update PR

The tenant template ships `.github/workflows/update-flake.yml`: a **weekly** job (Mondays)
that runs `nix flake update krg-infra` and opens a PR. Review + merge it and the next
converge picks up the new packages. This is the tenant equivalent of what krg-infra
maintainers do fleet-wide (`nix flake update nixpkgs` on krg-infra's `main`). **If you never
merge these, your instance freezes on old, unpatched packages** — the whole point of the
weekly PR is to make the security cadence a one-click review.

## Rollback

Generations are kept ~30 days (weekly GC). If a converge breaks the box:
```bash
nixos-rebuild list-generations           # what's available
nixos-rebuild switch --rollback          # back one generation
```
or pick an older generation from the boot menu. Because the pin bump is atomic, a bad
nixpkgs bump reverts cleanly — you never end up half-upgraded.

## Verify

```bash
uname -r                                 # running kernel (vs the built one after a bump)
nixos-rebuild list-generations           # recent generations + dates
systemctl status nixos-upgrade.service   # the nightly auto-upgrade's last run/result
```
If `nixos-upgrade.service` is failing, your instance is NOT getting patches — check it
targets `github:<owner>/<repo>#<name>` (not krg-infra), the exact bug this doc's fix closed.

## TL;DR

- **Apply** is automatic (nightly + on-merge, from your flake) — nothing to do.
- **Advance** is yours: merge the weekly `update-flake` PR (or run `nix flake update
  krg-infra` yourself). Skip it and you freeze on old packages.
- Kernel updates need a **reboot** (`allowReboot = false`); user-space doesn't.
- Rollback is one command; bumps are atomic.
