# Temporal frontend mTLS

> **Status: BUILT, UNVALIDATED.** This wiring has never booted on-box. The base
> Temporal stack itself was never deployed (see
> `docs/guacamole-temporal-consolidation.md`: "Temporal not deployed"), so first
> bring-up validates *both* the base stack and mTLS at once. Treat every claim
> here as a hypothesis until the validation gates below pass.

## Why

The Temporal gRPC frontend (`:7233`) is a cluster-admin surface: anyone who can
reach it can create/delete namespaces and start/terminate workflows. `auto-setup`
ships it **unauthenticated** (only the *UI* is gated, by Authentik OIDC). Before
the `terraform/temporal` provider can manage it — let alone before it's ever
exposed beyond the docker network — the frontend needs real client authentication.

mTLS solves it at the source: with `requireClientAuth`, only holders of a cert
signed by our CA can talk to `:7233`. This is a **private** CA, separate from the
public Let's Encrypt certs Traefik issues for the UI's browser HTTPS — mTLS certs
can't be public-CA issued, and these are machine endpoints. See
`terraform/openbao/pki.tf` for the CA.

## The pieces

| Layer | What | Where |
|---|---|---|
| **CA** | Two-tier private CA (root → intermediate) + `temporal-frontend` / `temporal-client` issuing roles | `terraform/openbao/pki.tf` |
| **Certs** | vault-agent issues + renders `frontend.pem`, `ca.crt`, `ui-client.pem` to `/run/krg/temporal/tls/` (tmpfs) on krg-prod | `nix/hosts/krg-prod/default.nix` (`krg.vaultAgent.renders`) |
| **Server** | `temporal` mounts the certs, requires client auth on `:7233` | `nix/docker-compose/krg-prod/compose.temporal.yml` |
| **UI** | `temporal-ui` presents its client cert to the frontend | same compose file |
| **Provider** | `terraform/temporal` issues itself a `temporal-client` cert (step 3, not yet built) | — |

## The auto-setup gotcha (and the fix)

`requireClientAuth` is a single switch shared by the **internode** and **frontend**
TLS configs. Two internal callers hit the frontend and would be locked out:

1. The **system Worker** role (in-process, but connects to the frontend over gRPC).
2. The **`auto-setup` bootstrap** — `register_default_namespace` and the
   `cluster health` wait both shell out to the `temporal` CLI against the frontend
   (`auto-setup.sh`).

Naively enabling `requireClientAuth` therefore **wedges first boot**. The fix is
the **internal-frontend**: `USE_INTERNAL_FRONTEND=true` stands up a second frontend
on `:7236` for internal traffic, and we don't put TLS on the internode path, so
`:7236` is **plaintext, localhost-only inside the container**. Then:

- `TEMPORAL_ADDRESS=127.0.0.1:7236` points the bootstrap CLI at the plaintext
  internal-frontend, so health/namespace setup never touches the mTLS `:7233`.
- The system Worker likewise uses the internal-frontend (`publicClient` is dropped
  when `USE_INTERNAL_FRONTEND` is set — see the config template).
- The **public** `:7233` is left to require client certs from external callers
  (the UI, the tofu provider, future workers).

### `BIND_ON_IP=0.0.0.0` (latent pre-TLS bug)

`auto-setup` defaults `bindOnIP` to `127.0.0.1` — **container-local**. With that
default `temporal-ui` (a separate container) can't reach `temporal:7233` *at all*,
TLS or not. We set `BIND_ON_IP=0.0.0.0` so the frontend binds all container
interfaces. Ports aren't published to the host (`krg.docker.defaultPublishAddress`
keeps unspecified publishes on loopback), and with mTLS the cross-container
reachability is gated by client-cert anyway.

## Cert rendering: one combined PEM per identity

Each `pki_int/issue/...` call mints a **fresh keypair**. If cert and key were
rendered to two separate files via two template blocks, they could come from two
different issuances → a cert paired with the wrong key → broken TLS. So each
identity is rendered as **one PEM containing cert + chain + key**, and both the
`*_CERT` and `*_KEY` env vars point at that one file (Go's
`tls.LoadX509KeyPair(f, f)` reads cert and key from the same file). `ca.crt` is
just the intermediate cert — no pairing concern.

## Bring-up

Prereq: `terraform/openbao` applied (so the PKI engine + roles + the widened
`krg-deploy`/`krg-prod` policies exist), and krg-prod's vault-agent AppRole can
already reach krg-vault (it renders the other krg-prod secrets today).

```bash
# 1. Apply the PKI engine + policy grants.
cd terraform/openbao
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"; export VAULT_TOKEN=…
tofu init && tofu apply

# 2. Deploy krg-prod. vault-agent renders the certs to /run/krg/temporal/tls,
#    then the temporal stack comes up with mTLS.
nixos-rebuild switch --flake ./nix#krg-prod \
  --target-host krg-admin@krg-prod.ucsd.edu --sudo --ask-sudo-password
```

## Validation gates (must pass before trusting this)

These are the facts the build assumes but could not be verified without a live
boot. Check each on-box:

1. **Certs render.** `/run/krg/temporal/tls/{frontend.pem,ca.crt,ui-client.pem}`
   exist, `frontend.pem` contains both a CERTIFICATE and a PRIVATE KEY block, and
   `openssl x509 -in frontend.pem -noout -text` shows SAN `DNS:temporal`.
2. **Server starts.** `docker logs temporal` shows no TLS load error and the
   bootstrap completes (`Registering default namespace` succeeds via `:7236`).
   This confirms `TEMPORAL_ADDRESS=127.0.0.1:7236` routes the CLI correctly and
   the CLI does **not** spuriously try TLS.
3. **UI connects.** `temporal-ui` reaches the frontend (workflows list loads),
   confirming the UI's TLS env var names (`TEMPORAL_TLS_CA/CERT/KEY/SERVER_NAME/
   ENABLE_HOST_VERIFICATION`) are correct for `temporalio/ui:2.51.0` and that
   `BIND_ON_IP=0.0.0.0` fixed cross-container reachability.
4. **mTLS is enforced.** A plaintext / no-cert gRPC probe to `:7233` is rejected;
   a probe presenting a `temporal-client` cert succeeds.
5. **Metrics intact.** Prometheus still scrapes `temporal:8000` (the metrics port
   is unrelated to frontend TLS, but confirm it didn't regress).

If gate 2 or 3 fails, the most likely culprits are the `temporal` CLI attempting
TLS against `:7236` (set the CLI's TLS-disable env explicitly) or the UI env var
names differing in this image tag (check `temporalio/ui` docs for the tag).

## Renewal

vault-agent here is a **oneshot** (`exit_after_auth`), so certs are re-issued on
each render — i.e. on deploy and on the nightly nixos-upgrade stack restart, well
inside the 30–90 day leaf TTLs. There is no in-place hot renewal; if a cert ever
expires between restarts, restart the stack (`systemctl restart <krg-prod stack>`)
to re-render. A long-running agent with `refreshInterval` is a future option.
