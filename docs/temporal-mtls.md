# Temporal frontend mTLS

> **Status: deployed 2026-06-16** (krg-prod); the gates below were run on-box during
> bring-up and passed — certs render, the server boots with mTLS on `:7233`, the
> bootstrap completes via the plaintext internal-frontend, the UI connects with its
> client cert, and a no-cert/plaintext probe to `:7233` is rejected. This was also the
> base Temporal stack's first real deploy.
>
> **Stale code comments:** the in-code comments still say `UNVALIDATED`
> (`nix/docker-compose/krg-prod/compose.temporal.yml` lines 29/67/120,
> `nix/hosts/krg-prod/default.nix` ~line 339) — they predate this bring-up and are a
> pending comment cleanup, **not** a signal that validation is outstanding. Drop them
> when next touching those files.
>
> Two bugs were found and fixed during bring-up:
>
> 1. **Cert dir not traversable.** `/run/krg/temporal/tls` was `0750 root`, so the
>    container (uid 1000) couldn't read the bind-mounted certs (`permission denied`
>    on `frontend.pem`). Fixed with the `dirPerms = "0755"` option on `krg.vaultAgent`
>    (parent `/run/krg/temporal` stays `0750`, so the host is still gated).
> 2. **internal-frontend configured but not run.** `USE_INTERNAL_FRONTEND` only
>    renders the config block; the server logged `Service is not requested ...
>    internal-frontend` and `:7236` never listened, so the bootstrap waited forever.
>    Fixed by adding it to the `SERVICES` run list (see below).

## Why

The Temporal gRPC frontend (`:7233`) is a cluster-admin surface: anyone who can
reach it can create/delete namespaces and start/terminate workflows. `auto-setup`
ships it **unauthenticated** (only the *UI* is gated, by Authentik OIDC). The
frontend is **published to the internet** (`:7233`) so off-site workers — e.g. the
NRP cluster — and the `terraform/temporal` provider can reach it, so it needs real
client authentication, not just network reach.

mTLS solves it at the source: with `requireClientAuth`, only holders of a cert
signed by our CA can talk to `:7233` — reachability is not the control, the cert
is. This is a **private** CA, separate from the public Let's Encrypt certs Traefik
issues for the UI's browser HTTPS — mTLS certs can't be public-CA issued, and these
are machine endpoints. See `terraform/openbao/pki.tf` for the CA.

## The pieces

| Layer | What | Where |
|---|---|---|
| **CA** | Two-tier private CA (root → intermediate) + `temporal-frontend` / `temporal-client` issuing roles | `terraform/openbao/pki.tf` |
| **Certs** | vault-agent issues + renders `frontend.pem`, `ca.crt`, `ui-client.pem` to `/run/krg/temporal/tls/` (tmpfs) on krg-prod | `nix/hosts/krg-prod/default.nix` (`krg.vaultAgent.renders`) |
| **Server** | `temporal` mounts the certs, requires client auth on `:7233` | `nix/docker-compose/krg-prod/compose.temporal.yml` |
| **UI** | `temporal-ui` presents its client cert to the frontend | same compose file |
| **Provider** | `terraform/temporal` issues itself a `temporal-client` cert and manages namespaces | `terraform/temporal/` |
| **Public ingress** | `:7233` published to the internet (mTLS-gated) for off-site workers + the provider | `compose.temporal.yml` (`ports`), `ansible/.../krg-prod.fw` |

## The auto-setup gotcha (and the fix)

`requireClientAuth` is a single switch shared by the **internode** and **frontend**
TLS configs. Two internal callers hit the frontend and would be locked out:

1. The **system Worker** role (in-process, but connects to the frontend over gRPC).
2. The **`auto-setup` bootstrap** — `register_default_namespace` and the
   `cluster health` wait both shell out to the `temporal` CLI against the frontend
   (`auto-setup.sh`).

Naively enabling `requireClientAuth` therefore **wedges first boot**. The fix is
the **internal-frontend**: a second frontend on `:7236` for internal traffic, with
no TLS on the internode path, so `:7236` is **plaintext, localhost-only inside the
container**. Enabling it is a **two-part** requirement (this bit us — getting only
one half leaves internal-frontend "configured but not requested", `:7236` never
listens, and the bootstrap waits forever):

- `USE_INTERNAL_FRONTEND=true` renders the internal-frontend **config block**.
- `SERVICES=frontend:internal-frontend:history:matching:worker` adds the role to
  the server's **run list** (`start-temporal.sh` starts only the default 4 roles
  otherwise — `internal-frontend` is not a default).

Then:

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

## Validation gates (verified 2026-06-16; re-run after changes)

These were unknowns at build time, all confirmed on-box during bring-up. Re-run
them after any change to the TLS env, certs, or image tags:

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
