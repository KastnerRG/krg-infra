# synology_certificate

Manage DSM Let's Encrypt certs declaratively from
[`spec/e4e-nas/certificates.yml`](../../../../spec/e4e-nas/certificates.yml).
Replaces the manual "DSM → Control Panel → Security → Certificate → Get a
cert from Let's Encrypt" wizard step. Git is truth; UI changes / DSM-default
swaps are drift ([ADR 0001](../../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

[`files/apply_certificate.py`](files/apply_certificate.py) (shipped via the
`script` module; DSM py3.8) — three subcommands, run in load-bearing order
by `tasks/main.yml`:

| subcommand | what it does | idempotency |
|---|---|---|
| `letsencrypt-create` | Issue / re-issue an LE cert for one domain. Probes `SYNO.Core.Certificate.CRT.list`; no-op if a matching cert (by common-name) has > `renewal_buffer_days` of life left, otherwise calls `SYNO.Core.Certificate.LetsEncrypt.create`. | Common-name match + valid_till compare |
| `set-default`        | Bind the matching cert as DSM's default (`SYNO.Core.Certificate.CRT.set_default`). | `is_default` flag |
| `list`               | Read-only — dump certs in trimmed JSON. Used by the drift-export tag. | n/a |

The role does **not** drive LE renewal cadence — DSM has its own cron-driven
renewal. The `renewal_buffer_days` window is a *safety net*: if a cert
exists but expires inside the window, the role re-issues, catching silently-
broken DSM renewal. In steady state DSM keeps the cert fresh and the role
exits no-change.

## ADR 0007 fit

The synology-community Terraform provider exposes **no certificate
resources** (its "certificate" surface is about *its own* TLS verification
when calling DSM, not about managing DSM-side certs). Per the ADR's
provider-modeled-surface rule, this concern belongs in Ansible.

## Pre-requisites

- DSM with SSH + key-only login set up (handled by `synology_base`).
- The target domain must resolve to the NAS's public IP and have port 80
  reachable from the internet (Let's Encrypt HTTP-01 challenge). The role
  surfaces a clean FAIL with DSM's response if these aren't met.
- DSM web reachable from the operator's network (so the role's `script:`
  invocation lands).

## Run

```bash
# Full role: issue + bind default
ansible-playbook playbook.yml --tags=synology_certificate

# Dry-run (preview without issuing)
ansible-playbook playbook.yml --tags=synology_certificate --check --diff

# Drift snapshot to /var/lib/krg-deploy/synology-export/<host>-certificates.json
ansible-playbook playbook.yml --tags=export
```

## Decommission

`rm -rf ansible/synology/roles/synology_certificate/` + remove the role from
`playbook.yml` + remove `spec/e4e-nas/certificates.yml`. DSM's existing
certs are untouched (the role only ADDS / re-issues; it never deletes).

## Validation

Pytest suite under `files/test_apply_certificate.py` covers:

- `valid_till` parsing (GMT / UTC / unparseable)
- domain-match lookup including ambiguity refusal (multiple certs sharing CN)
- `letsencrypt-create`: no-change with buffer, re-issue inside buffer, first-issuance, check-mode dry-run, defensive re-issue on unparseable expiry, structured FAIL on LE API failure / list-API failure / bad SANs JSON
- `set-default`: no-change when already default, bind when not, FAIL on missing cert, check-mode dry-run
- `list`: trim-shape contract, structured FAIL on API failure
- argparse plumbing for both write subcommands

Run from the repo root: `pytest ansible/synology/roles/synology_certificate/files/test_apply_certificate.py`

## Out of scope

- **Service-specific cert bindings** (e.g. AppPortal reverse-proxy entries
  for garage-ui on `:8443`, future MLflow public URL) — belong in
  [`synology_app_portal`](../synology_app_portal/), not here. The split is
  "this role owns which certs EXIST + which is DEFAULT; that role owns
  which services use WHICH cert."
- **Renewal cadence** — DSM cron-driven, not us. The `renewal_buffer_days`
  window is a safety net for silently-broken renewal, not the renewal
  driver itself.
- **Cert deletion** — the role doesn't remove certs not in spec. Manual
  cleanup via DSM UI for now (rare operation).
- **DNS-01 / wildcard certs** — only HTTP-01 single-domain certs today;
  wildcard would need an LE DNS-01 challenge integration with the DNS
  provider, which we don't currently have IaC for.

## Roadmap

- Wildcard certs once `garage.e4e-nas.ucsd.edu` ([#118](https://github.com/KastnerRG/krg-infra/issues/118)) lands and we want `*.s3.garage.e4e-nas.ucsd.edu` for virtual-host-style S3 routing.
- Service-binding subcommand (one-line wrapper around `SYNO.Core.Certificate.Service`) — defer until we have a second cert to bind to a service explicitly.
