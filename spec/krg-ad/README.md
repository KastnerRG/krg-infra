# `spec/krg-ad/` — KRG.LOCAL Active Directory, declarative

Source of truth for the **structural** content of the KRG.LOCAL Samba AD forest
(on `krg-ldap`). Consumed by the `ansible/krg-ad/` role, which converges the live
directory to these files by wrapping `samba-tool` on the DC. See
[ADR 0010](../../docs/adr/0010-active-directory-structure-as-iac.md) for the
rationale and the ownership boundary.

## What lives here (IaC) vs. what doesn't (roster)

| Concern | Owner | File |
| --- | --- | --- |
| Group objects (existence, scope, category, description) | **IaC** | `groups.yml` |
| Nested group membership (a group inside another group, via `members:`) | **IaC** | `groups.yml` |
| Service / automation accounts + their group membership | **IaC** | `service-accounts.yml` |
| Delegated ACL grants to service accounts | **IaC** | `acls.yml` |
| Domain password policy (length, complexity, expiry, history) | **IaC** | `password-policy.yml` |
| **Human accounts + their group membership** | **roster** (`svc_roster`) | — not here — |

## Load-bearing invariants

- **Non-authoritative on membership.** The apply *adds* groups, service-account
  memberships, and ACEs; it **never removes** a member, ACE, or group that isn't
  in the spec. This is deliberate: human group membership is roster's, and an
  authoritative reconcile would delete roster-set members on every run. Drift
  (live groups not in spec) is *reported*, not enforced.
- **No secrets.** Passwords never appear in these files. Missing service accounts
  are reported, not auto-created (their password lives in OpenBao).
- **Seeded from live, read-only.** Every value here was captured from the running
  DC on 2026-06-17 via read-only `samba-tool`/`ldbsearch`. Re-confirm before
  trusting `description`/`TODO` lines flagged as unverified.

## Apply

```bash
cd ansible/krg-ad
ansible-playbook playbook.yml --check    # dry run (diff only)
ansible-playbook playbook.yml            # converge
```
or via the control node: `DEPLOY_KRG_AD=true deploy/deploy-ansible.sh`.
