# synology_certificate

Manage DSM Let's Encrypt certs declaratively from
[`spec/e4e-nas/certificates.yml`](../../../../spec/e4e-nas/certificates.yml).
Replaces the manual "DSM → Control Panel → Security → Certificate → Get a
cert from Let's Encrypt" wizard step. Git is truth; UI changes / DSM-default
swaps are drift ([ADR 0001](../../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

[`files/apply_certificate.py`](files/apply_certificate.py) (shipped via the
`script` module; DSM py3.8) — four subcommands, run in load-bearing order
by `tasks/main.yml`:

| subcommand | what it does | idempotency |
|---|---|---|
| `letsencrypt-create` | Issue / re-issue an LE cert for one domain. Probes `SYNO.Core.Certificate.CRT.list`; no-op if a matching cert (by common-name) has > `renewal_buffer_days` of life left, otherwise calls `SYNO.Core.Certificate.LetsEncrypt.create` with the wizard-captured shape (`desc + domain_name + email`). | Common-name match + valid_till compare |
| `set-default`        | Mark the matching cert as DSM's default for NEW services (`SYNO.Core.Certificate.CRT.set` with `as_default=true` + `desc` + `id` — *not* `set_default`; the latter doesn't exist on DSM 7.3, the wizard uses `set`). | `is_default` flag |
| `bind-services`      | Migrate EXISTING service bindings (DSM web, FTPS, KMIP, ...) onto the spec's cert (`SYNO.Core.Certificate.Service.set` with nested `service` object + `old_id` + `id`). Required because `as_default=true` only flags which cert NEW services get — it does not migrate the bindings DSM already has. | Skips (service, subscriber) tuples already on the target cert |
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
- **Firewall must allow inbound TCP/80 from ANY source** — not just US
  geoip. LE's Multi-Perspective Issuance Corroboration (MPIC, enforced
  since 2024-06-15) validates from multiple geographically distributed
  vantage points including outside the US. A US-only geoip allow blocks
  LE's non-US secondary validators → cert issuance fails with "Timeout
  during connect" in DSM's cert log. The `lets-encrypt-http-01` rule in
  `spec/e4e-nas/security.yml` `firewall.profiles.default.adapters.global.rules`
  carries this allow; `synology_security` enforces it. If you applied
  this role and `synology_security` isn't applied (or its spec doesn't
  have that rule), expect 5503/timeout errors regardless of how correct
  the API params are.

## Run

```bash
# Full role: issue + bind default
ansible-playbook playbook.yml --tags=synology_certificate

# Dry-run (preview without issuing)
ansible-playbook playbook.yml --tags=synology_certificate --check --diff

# Drift snapshot to /var/lib/krg-deploy/synology-export/<host>-certificates.yml
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
- `bind-services`: no-change when already on target cert, migrate when on factory/other cert, partial change across multiple bindings, warn-and-skip on services DSM doesn't have, FAIL on bad bindings JSON / missing cert, check-mode dry-run
- `list`: trim-shape contract, structured FAIL on API failure
- argparse plumbing for all three write subcommands

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

- Wildcard certs for virtual-host-style S3 routing (`*.s3.e4e.ucsd.edu`, per-bucket hostnames) — [#118](https://github.com/KastnerRG/krg-infra/issues/118). The path-style `s3.e4e.ucsd.edu` + `s3-admin.e4e.ucsd.edu` endpoints use SANs on the host cert (see `spec/e4e-nas/certificates.yml`).
- DNS-01 challenge integration (would let us close port 80 entirely; needs programmatic update access to the `ucsd.edu` zone, which we don't have today — see security.yml comment on `lets-encrypt-http-01`).
