# synology_dsm_web

Manage DSM **web service settings** on the Synology (e4e-nas) from
[`spec/e4e-nas/dsm-web.yml`](../../../spec/e4e-nas/dsm-web.yml): HTTPS / HSTS /
HTTP/2 (SPDY) / mDNS (Avahi) / SSDP / DSM ports / **TLS compatibility profile**. Git is
the source of truth, UI changes are drift
([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

[`files/apply_dsm_web.py`](files/apply_dsm_web.py) (shipped via the `script` module; DSM
py3.8) drives two synowebapi APIs:

- **`SYNO.Core.Web.DSM` v2** — full-object set (partial = err 2001, like `synology_smb`),
  so the helper GETs the current object, overlays managed keys, and SETs the whole thing
  back, only on drift.
- **`SYNO.Core.Web.Security.TLSProfile` v1** — simpler `default-level: <int>` set.
  The helper maps the spec name (`modern|intermediate|old`) to DSM's integer via
  `TLS_LEVELS`. Mapping is **community-best-known**, not empirically confirmed on this
  box; verify on the first rebuild apply and flip `TLS_LEVELS` in the helper if needed.

## Managed keys

| spec key (`web:` / `tls:`) | DSM field | role default |
|---|---|---|
| `enable_hsts` | `enable_hsts` (bool) | true |
| `enable_avahi` (mDNS off) | `enable_avahi` (bool) | false |
| `enable_ssdp` (UPnP off) | `enable_ssdp` (bool) | false |
| `enable_spdy` (HTTP/2) | `enable_spdy` (bool) | true |
| `enable_https` | `enable_https` (bool) | true |
| `enable_https_redirect` | `enable_https_redirect` (bool) | true |
| `enable_server_header` | `enable_server_header` (bool) | false |
| `http_port` | `http_port` (int) | 6020 |
| `https_port` | `https_port` (int) | 6021 |
| `tls.profile` | `default-level` (int, via `TLS_LEVELS`) | `intermediate` |

## Run

```bash
ansible-playbook playbook.yml                 # apply
ansible-playbook playbook.yml --check --diff  # report drift, change nothing
ansible-playbook playbook.yml --tags export   # snapshot → <host>-dsm-web.yml
```

## Validation status

Logic unit-tested ([`files/test_apply_dsm_web.py`](files/test_apply_dsm_web.py): TLS
mapping, web full-object drift detection, `--check` self-gating, the CHANGED/FAIL
contract). End-to-end on the DSM 7.3 rig is **pending** (rig down at time of writing;
follow the same drift→check→apply→idempotent flow as `synology_smb` once it's back up).
Per-field DSM set semantics — particularly the TLS integer mapping — should be confirmed
once on the rig before applying to prod.
