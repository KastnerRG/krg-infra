# 0010. Active Directory structure is IaC; human identity is roster's

**Status:** Accepted · **Date:** 2026-06-17

## Context

KRG.LOCAL (the Samba AD forest on `krg-ldap`) is the lab's single identity
authority — host logins, Grafana/Authentik SSO, `/scratch` group ownership, GPU
and Docker access all key off AD groups ([[authentik-groups-from-ad]],
`krg.adClient`, `ad-group-sync.nix`). Yet it was the **one managed system in this
repo not under declarative IaC.** Everything else flows through a spec → module/
role/resource → orchestrator (ADR 0001, ADR 0005). AD content — groups, service
accounts, ACL delegations, the password policy — was created ad hoc with
`samba-tool` on the DC and documented only as runbook prose
([docs/creating-a-user.md](../creating-a-user.md)).

That is drift by construction: nothing in git describes the directory, so a hand-
created group or a delegated right is invisible the moment it lands — the exact
failure ADR 0001 exists to prevent. Two things forced the decision now:

1. **A concrete break.** Authentik self-service password change failed with
   `LDAPInsufficientAccessRightsResult (50)` — the `authentik-bind` account
   could read/sync the directory but lacked the *Reset Password* right to write a
   new `unicodePwd` back to AD. The fix is a scoped ACL delegation; left as a
   one-off `samba-tool dsacl set` it would be precisely the invisible drift this
   ADR rejects.
2. **The group/ACL matrix is being built right now** ([[krg-local-ad-principals-pending]]).
   Capturing it declaratively as it's created is "extend the role NOW, same five
   minutes" — far cheaper than reverse-engineering a hand-built directory later.
   And this whole repo exists because of a breach-driven rebuild: if `krg-ldap`
   is lost and the forest is re-provisioned from scratch, every undocumented
   `samba-tool` step is gone. A declared directory is deterministic DR.

The sharp question is **how much** of AD to put under IaC. AD content is a live,
replicated, security-critical database; over-managing it (especially human
accounts and passwords) risks lockout and fights the systems that legitimately
mutate it day to day.

## Decision

### 1. Split by *who owns the write*, not by object type

- **IaC (`spec/krg-ad/` + `ansible/krg-ad/`)** owns the directory's **structure**:
  group objects, service/automation accounts and *their* group membership,
  delegated ACL grants, and the domain password policy.
- **Roster (`svc_roster`)** owns **human identity**: human accounts and the group
  membership *of those human accounts*. Roster is an operational system — people
  join and leave constantly — and that churn is not infrastructure.

Service accounts are IaC because they're infrastructure principals (a bind
account, an automation account); humans are roster's because they're population.

### 2. The apply is NON-AUTHORITATIVE on membership (and on existence)

This is the load-bearing invariant that lets two writers coexist. The
`ansible/krg-ad/` apply only ever **adds** groups, service-account memberships,
and ACEs, and converges the password policy. It **never deletes** a group, a
member, or an ACE that is absent from the spec. Group membership has two writers
(roster for humans, IaC for service accounts); an authoritative "set members =
spec list" reconcile — the model `ansible/synology/` uses for the NAS — would
**delete every roster-set human** from a group on the next run. So we borrow the
synology pattern's *shape* (spec + a `samba-tool`-wrapping apply with unit tests)
but explicitly **not** its authoritative-delete. Drift (live groups not in spec)
is *reported*, never enforced; deleting an AD object stays a deliberate human act.

### 3. Password policy: no expiry + the UCSD AD standard

Folded into `spec/krg-ad/password-policy.yml` (applied via
`samba-tool domain passwordsettings set`):

- **Passwords do not expire** (`max_pwd_age = 0`; was 42 days). Mandatory periodic
  rotation is deprecated guidance — it drives users to weaker, predictably-
  incremented secrets without reducing compromise (NIST SP 800-63B §5.1.1.2:
  rotate on evidence of compromise, not on a clock). Service accounts benefit
  most: a silently-expired `authentik-bind`/`svc_roster` breaks SSO/roster.
- **UCSD AD password standard**: minimum length **12** (was 7), **complexity on**
  (≥3 of 4 character categories + not-username), history 24 ("different from
  previous"). Source: UCSD Blink "Password Security"
  (blink.ucsd.edu/technology/network/access/secure-passwords.html), which mandates
  "at least 12 characters", "3 of 4 categories", and prefers passphrases (15+).

### 4. The same mandate spans two layers — AD *and* Authentik

UCSD also wants "not a single recognizable word" + (best practice) breached-
password screening. **AD password policy cannot express that** — no dictionary or
breach check. So the standard is met by **two layers together**: AD enforces
length/complexity/history/expiry; **Authentik** enforces strength + breach
screening via a password-strength policy (zxcvbn + HaveIBeenPwned) bound to its
enrollment and password-change flows.

**Where enforcement actually happens (the nuance that scopes the obligation).**
For AD-sourced users — i.e. every human — Authentik does not store the password;
its password-change flow **writes back to Samba AD** (`unicodePwd`), and Samba
enforces the domain policy *on that write*. So the length/complexity bar set here
is **already enforced for AD users even before any Authentik policy exists** — a
non-compliant password is rejected at the AD write step (fail-closed; it surfaces
as a generic "Failed to update user", same shape as the ACL break that motivated
this ADR). The Authentik policy is therefore **not** what makes AD users compliant
on length/complexity. What still has *no* enforcement anywhere is:

1. **Breach/dictionary screening** ("not a recognizable word") — only Authentik
   (HIBP/zxcvbn) can do it; AD cannot.
2. **Local (non-AD) Authentik accounts** — e.g. the `akadmin` bootstrap — have no
   AD write-back, so *only* an Authentik policy bounds them.
3. **UX** — a client-side policy rejects weak input *in the form* with a clear
   message, instead of the opaque AD-write failure.

The Authentik half lives in `terraform/authentik/` — which currently declares
**no** password policy or flows (verified: it manages apps/providers/groups/LDAP/
outpost/secrets only) — and is owned by the parallel SSO effort
([[terraform-openbao-authentik-hands-off]]), **not** this change. It is recorded
here as a **cross-layer obligation**: AD users are covered for length/complexity
today, but the mandate is not *fully* satisfied (breach screening, local accounts,
UX) until that policy lands. This ADR owns the AD half and the requirement on the
Authentik half.

## Consequences

- The first concrete payoff: the `authentik-bind` *Reset Password* delegation
  (`spec/krg-ad/acls.yml`) is now IaC, and applying it fixes the password-change
  break — the fix and its record are the same artifact.
- `spec/krg-ad/` is the DR manifest for the directory's structure. Re-provisioning
  a forest + running the apply rebuilds groups/service-accounts/ACLs/policy.
- AD now has the same shape as the rest of the repo: spec is truth, hand edits are
  drift. `docs/creating-a-user.md` remains the *human* runbook (roster's domain).
- A second DC (the `krg-ldap` SPOF removal) needs no change here — AD replicates;
  pin one DC as the write target in `ansible/krg-ad/inventory.yml`.

## Alternatives considered

- **Terraform LDAP provider.** Could model AD objects as resources, but the
  community LDAP/AD providers are weak, and Terraform's value is its
  authoritative drift model — which is exactly what we must *not* apply to
  membership. The samba-tool-wrapping apply fits the "converge a CLI-only system,
  non-authoritatively" need better. (Parallels ADR 0007's reasoning for DSM.)
- **A NixOS module on krg-ldap.** Rejected: `samba-tool domain provision` is
  explicitly *not* Nix-managed (it generates a stateful SAM database +
  secrets — see `nix/modules/samba-ad.nix`), and the flake can only read the
  `nix/` subtree, so it couldn't consume `spec/krg-ad/`. Nix owns the DC
  *runtime*; ansible owns the directory *content*.
- **Authoritative reconcile (synology model).** Rejected for membership — it would
  delete roster-managed human members. Adopted only for the password policy,
  which has a single writer.
- **Manage humans in IaC too.** Rejected: passwords are secrets, and human churn
  is operational, not infra. Roster already owns it.

## Out of scope / follow-ups

- **Authentik password-strength + breach policy** — owed in `terraform/authentik/`
  (decision 4); the UCSD mandate isn't fully met until it lands.
- **Account lockout policy** — live threshold is 0 (off). AD/Kerberos lockout
  enables targeted user-DoS, and SSH is already covered by fail2ban + key-only
  auth behind a source-restricted perimeter; left as a deliberate future decision
  rather than flipped as a side effect of this change.
- **Existing-group description reconcile** — the apply sets a description only at
  group creation (samba-tool has no scriptable setter; `ldbmodify` deferred).
- **Wire into CD** — `deploy/deploy-ansible.sh` runs the apply behind
  `DEPLOY_KRG_AD=true`; a nightly timer (like `ansible-apply`) is a follow-up.
