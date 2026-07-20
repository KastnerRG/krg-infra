#!/usr/bin/env python3
"""Deploy + configure Garage on DSM Container Manager idempotently.

Subcommands:
  render-config  Write /volume1/docker/garage/garage.toml (root:root 0400) from
                 structural CLI flags + 3 secrets read from environment
                 (GARAGE_RPC_SECRET, GARAGE_ADMIN_TOKEN, GARAGE_METRICS_TOKEN —
                 NOT cmdline args, to keep them out of /proc/<pid>/cmdline /
                 `ps`/`top`). Atomic write; sha256 compare for idempotency.
                 Stdout payload deliberately omits secret values; it only
                 emits `desired_sha256` so the operator can confirm a
                 meaningful change without the bytes leaking.
  deploy         Write docker-compose.yml + `docker compose up -d` when the
                 effective container state (image / mounts / env / restart)
                 drifts from spec. garage.toml must exist before this runs
                 (the container crash-loops on missing /etc/garage.toml).
  layout        Single-node Garage layout bootstrap — `garage layout assign`
                 + `garage layout apply`. Idempotent: exits no-change once
                 the active layout names our node. Refuses to mutate an
                 already-defined layout (anti-rebalance guard — capacity
                 bumps are an operator-driven side-effect, not auto-applied).
  sync-buckets  Create-if-missing buckets from spec.buckets, via the Garage
                v2 Admin API (not the CLI — JSON, already documented, and the
                admin API is reachable on loopback since the container uses
                network_mode: host). Idempotent: existing global aliases are
                left alone.
  sync-keys     Import-if-missing access keys from spec.keys, using the
                credentials the control node provisioned in OpenBao and passed
                via GARAGE_KEY_CREDENTIALS_JSON (ImportKey, not CreateKey), then
                converge each key's per-bucket read/write/owner grants via
                AllowBucketKey / DenyBucketKey. OpenBao is the source of truth;
                <keys-dir>/<name>.env (root:root 0400) is a render of it, so a
                lost keys_dir is restored with no rotation. FAILs only on real
                divergence: a key present on Garage whose id differs from the
                one OpenBao holds (out-of-band rotation).

Why direct `docker compose` and not DSM's SYNO.Docker.Project: the synology-
community/synology terraform provider hit three bugs against that API
(#110 secrets.content not sensitive, #113 FileStation index instability,
#114 JSON parse on streamed docker-compose output). See ADR 0007 "Garage
retreat". docker compose is the underlying primitive, idempotent at its
layer; the container still shows in DSM Container Manager's Container tab,
just not as a "Project".

Invoked by the synology_garage ansible role via the `script` module. Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>. The
render-config output deliberately omits the secret values from any
WOULD-CHANGE/CHANGED payload (only emits `desired_sha256`, a fingerprint
of the rendered config that lets operators confirm meaningful change).

Key secrets: sync-keys' CHANGED/WOULD-CHANGE payloads never carry a
secretAccessKey either — same posture as render-config/render-ui-config.
The credential itself comes IN from OpenBao (control node → env var, never
argv), so OpenBao — not the box — is the durable copy; the <name>.env is a
0400 render of it that ImportKey/restore rewrites. See
roles/synology_garage/README.md "Secrets".
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


# DSM Container Manager ships docker under non-standard paths that sudo's
# secure_path doesn't include — `docker` is invisible to subprocess unless we
# prepend the install locations. Adding both v7.2+ (Container Manager) and
# legacy (Docker package) targets so this works across DSM versions.
_DSM_DOCKER_PATHS = (
    "/usr/local/bin",  # symlink target on most DSM 7.x
    "/var/packages/ContainerManager/target/usr/bin",  # DSM 7.2+ Container Manager
    "/var/packages/Docker/target/usr/bin",  # legacy DSM ≤ 7.1 Docker package
)
os.environ["PATH"] = ":".join(_DSM_DOCKER_PATHS) + ":" + os.environ.get("PATH", "")


# ---------------------------------------------------------------------------
# garage.toml template
# ---------------------------------------------------------------------------
# Hand-rolled, %-formatted: python 3.8 ships no `tomllib`, third-party `toml`
# is not in DSM. Keys map 1:1 to spec.config + the 3 secrets.
GARAGE_TOML_TEMPLATE = """\
# RENDERED BY synology_garage ansible role — DO NOT HAND-EDIT.
# Source of truth: spec/e4e-nas/garage.yml + extra_vars secrets.
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "%(db_engine)s"

replication_factor = %(replication_factor)d

compression_level = %(compression_level)d

rpc_bind_addr = "%(rpc_bind_addr)s"
rpc_public_addr = "%(rpc_public_addr)s"
rpc_secret = "%(rpc_secret)s"

[s3_api]
api_bind_addr = "%(s3_api_bind_addr)s"
s3_region = "%(s3_region)s"
root_domain = "%(s3_root_domain)s"

[s3_web]
bind_addr = "%(s3_web_bind_addr)s"
root_domain = "%(s3_web_root_domain)s"
index = "%(s3_web_index)s"

[admin]
api_bind_addr = "%(admin_api_bind_addr)s"
admin_token = "%(admin_token)s"
metrics_token = "%(metrics_token)s"
"""

# docker-compose.yml — same hand-rolled approach. Keep the YAML simple +
# stable so the sha256 diff is meaningful (no key-ordering surprises).
COMPOSE_TEMPLATE = """\
# RENDERED BY synology_garage ansible role — DO NOT HAND-EDIT.
# Source of truth: spec/e4e-nas/garage.yml deployment block.
services:
  %(container_name)s:
    image: %(image)s:%(image_tag)s
    container_name: %(container_name)s
    restart: %(restart_policy)s
    network_mode: %(network_mode)s
    environment:
      RUST_LOG: %(rust_log)s
    volumes:
      - %(meta_dir)s:/var/lib/garage/meta
      - %(data_dir)s:/var/lib/garage/data
      - %(config_path)s:/etc/garage.toml:ro
"""


# --- garage-ui (Noooste/garage-ui) -----------------------------------------
# Two templates: the UI's own config.yaml (carries the OIDC client_secret →
# rendered with no_log, secret read from env not argv) and the UI's compose
# file (no secrets). UI runs with `network_mode: host` so it can reach garage
# on localhost:3900/3903; its own bind is locked to 127.0.0.1 via server.host
# so DSM AppPortal is the only public path.
GARAGE_UI_CONFIG_TEMPLATE = """\
# RENDERED BY synology_garage ansible role — DO NOT HAND-EDIT.
# Source of truth: spec/e4e-nas/garage.yml `ui:` block + the
# GARAGE_UI_OIDC_CLIENT_SECRET env var.
server:
  host: "%(bind_host)s"
  port: %(port)d
  environment: production
  domain: "%(public_hostname)s"
  protocol: https
  root_url: "%(public_url)s"

garage:
  endpoint: "http://127.0.0.1:%(garage_s3_port)d"
  region: "%(garage_region)s"
  admin_endpoint: "http://127.0.0.1:%(garage_admin_port)d"
  admin_token: "%(garage_admin_token)s"

auth:
  jwt_private_key: "%(jwt_private_key)s"
  admin:
    enabled: false
  token:
    enabled: false
  oidc:
    enabled: true
    provider_name: "%(oidc_provider_name)s"
    client_id: "%(oidc_client_id)s"
    client_secret: "%(oidc_client_secret)s"
    scopes:
%(oidc_scopes_yaml)s
    issuer_url: "%(oidc_issuer_url)s"
    skip_issuer_check: false
    skip_expiry_check: false
    email_attribute: "email"
    username_attribute: "preferred_username"
    name_attribute: "name"
    role_attribute_path: "%(oidc_role_attribute_path)s"
    admin_roles:
%(oidc_admin_roles_yaml)s
    tls_skip_verify: false
    session_max_age: 86400
    cookie_name: "garage_ui_session"
    cookie_secure: true
    cookie_http_only: true
    cookie_same_site: "lax"

cors:
  enabled: false

logging:
  level: "info"
  format: "json"
"""

GARAGE_UI_COMPOSE_TEMPLATE = """\
# RENDERED BY synology_garage ansible role — DO NOT HAND-EDIT.
# Source of truth: spec/e4e-nas/garage.yml `ui:` block.
# NOTE: garage + garage-ui are SEPARATE compose projects, so no
# `depends_on:` (cross-project depends aren't supported). If garage isn't
# up yet, `restart: unless-stopped` reconverges. Both use host networking,
# so UI reaches garage at 127.0.0.1:3900 / 127.0.0.1:3903.
#
# The image has NO ENTRYPOINT and `CMD ["./garage-ui"]` (WORKDIR /app); it reads
# config from the FIXED path /app/config.yaml automatically — there is no
# `--config` flag. So we do NOT override `command:` (overriding it dropped the
# binary → docker exec'd "--config" as argv[0]) and mount the config to
# /app/config.yaml.
#
# We DON'T override `user:` — the image runs as its non-root USER garageui
# (UID 1000), and render-ui-config writes config.yaml owned by that UID (mode
# 0400) so the container can read its own secret-bearing config without running
# as root. See _GARAGE_UI_UID.
services:
  %(container_name)s:
    image: %(image)s:%(image_tag)s
    container_name: %(container_name)s
    restart: unless-stopped
    network_mode: host
    volumes:
      - %(config_path)s:/app/config.yaml:ro
"""


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _run(*cmd, **kw):
    """subprocess.run wrapper that turns FileNotFoundError (binary not on PATH)
    into a structured non-zero CompletedProcess. Without this, calling
    `_run("docker", …)` on a box without docker installed raises a Python
    traceback that bypasses the OK/WOULD-CHANGE/CHANGED/FAIL contract."""
    try:
        return subprocess.run(list(cmd), capture_output=True, text=True, **kw)
    except FileNotFoundError as e:
        return subprocess.CompletedProcess(
            args=list(cmd),
            returncode=127,
            stdout="",
            stderr="binary not found on PATH: "
            + (cmd[0] if cmd else "<empty>")
            + " ("
            + str(e)
            + ")",
        )


def _sha256(content):
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def _read(path):
    try:
        with open(path, "r") as fh:
            return fh.read()
    except (FileNotFoundError, IsADirectoryError):
        return None


def _atomic_write(path, content, mode, uid=0, gid=0):
    """Write `content` to `path` via tmp+rename; chmod + chown (default root:root).
    Same dir as the target so rename is atomic on the same filesystem.
    `uid`/`gid` let a secret file be owned by a non-root container's runtime UID
    so that container can read it WITHOUT the container running as root (see
    _GARAGE_UI_UID)."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".krg-", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        os.chmod(tmp, mode)
        os.chown(tmp, uid, gid)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def _emit(state, payload, check):
    if state == "no-change":
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(payload, sort_keys=True))
        return 0
    print("CHANGED " + json.dumps(payload, sort_keys=True))
    return 0


def _fail(payload):
    print("FAIL " + json.dumps(payload))
    return 1


# ---------------------------------------------------------------------------
# render-config — write garage.toml from CLI flags + secrets
# ---------------------------------------------------------------------------
_SECRET_ENV_VARS = ("GARAGE_RPC_SECRET", "GARAGE_ADMIN_TOKEN", "GARAGE_METRICS_TOKEN")


def do_render_config(a):
    # Secrets come from the environment, not argv, so they don't appear in
    # /proc/<pid>/cmdline / `ps` / `top` while the script runs. Ansible's
    # `script:` task passes them via `environment:` (no_log:true keeps them
    # out of the ansible-side capture too).
    missing = [v for v in _SECRET_ENV_VARS if not os.environ.get(v)]
    if missing:
        return _fail({"reason": "required secret env vars unset", "vars": missing})
    fields = {
        "db_engine": a.db_engine,
        "replication_factor": int(a.replication_factor),
        "compression_level": int(a.compression_level),
        "rpc_bind_addr": a.rpc_bind_addr,
        "rpc_public_addr": a.rpc_public_addr,
        "rpc_secret": os.environ["GARAGE_RPC_SECRET"],
        "s3_api_bind_addr": a.s3_api_bind_addr,
        "s3_region": a.s3_region,
        "s3_root_domain": a.s3_root_domain,
        "s3_web_bind_addr": a.s3_web_bind_addr,
        "s3_web_root_domain": a.s3_web_root_domain,
        "s3_web_index": a.s3_web_index,
        "admin_api_bind_addr": a.admin_api_bind_addr,
        "admin_token": os.environ["GARAGE_ADMIN_TOKEN"],
        "metrics_token": os.environ["GARAGE_METRICS_TOKEN"],
    }
    # Reject any literal `"`, `\n`, or `\r` in a string field — these
    # would close the TOML basic-string literal early and inject content
    # (basic strings can't contain raw newlines either). Cheap defense at
    # the bottleneck; the template uses double-quoted basic strings only,
    # no triple-quoted blocks.
    for k, v in fields.items():
        if isinstance(v, str) and ('"' in v or "\n" in v or "\r" in v):
            return _fail({"reason": "field contains unescaped quote or newline", "field": k})

    desired = GARAGE_TOML_TEMPLATE % fields
    desired_hash = _sha256(desired)
    current = _read(a.config_path)
    current_hash = _sha256(current) if current is not None else None

    if current_hash == desired_hash:
        return _emit("no-change", {}, a.check)

    # No secret values in the payload — only the fact that secrets-bearing
    # content changed. Keep no_log honest even if the operator forgot.
    payload = {
        "config_path": a.config_path,
        "had_existing": current is not None,
        "desired_sha256": desired_hash,
    }
    if a.check:
        return _emit("would-change", payload, True)

    _atomic_write(a.config_path, desired, 0o400)
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# deploy — render docker-compose.yml + `docker compose up -d` when drifting
# ---------------------------------------------------------------------------
def _container_running(name):
    r = _run("docker", "inspect", "--format", "{{.State.Running}}", name)
    return r.returncode == 0 and r.stdout.strip() == "true"


def _container_image(name):
    r = _run("docker", "inspect", "--format", "{{.Config.Image}}", name)
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def do_deploy(a):
    fields = {
        "container_name": a.container_name,
        "image": a.image,
        "image_tag": a.image_tag,
        "network_mode": a.network_mode,
        "restart_policy": a.restart_policy,
        "rust_log": a.rust_log,
        "meta_dir": a.meta_dir,
        "data_dir": a.data_dir,
        "config_path": a.config_path,
    }
    desired_compose = COMPOSE_TEMPLATE % fields
    current_compose = _read(a.compose_path)

    # garage.toml MUST exist before docker can mount it. In --check mode the
    # operator may legitimately be previewing on a fresh box (render-config
    # hasn't run yet) — treat as a planned change (WOULD-CHANGE) rather than
    # failing the dry run. In real apply mode it's a hard ordering bug.
    config_missing = not os.path.exists(a.config_path)
    if config_missing:
        if not a.check:
            return _fail(
                {
                    "reason": "garage.toml missing — run render-config first",
                    "config_path": a.config_path,
                }
            )
        return _emit(
            "would-change",
            {
                "compose_path": a.compose_path,
                "config_missing": True,
                "reason": "render-config must run before deploy on apply",
            },
            True,
        )

    desired_image = "%s:%s" % (a.image, a.image_tag)
    compose_drift = current_compose != desired_compose
    current_image = _container_image(a.container_name)
    image_drift = current_image != desired_image
    not_running = not _container_running(a.container_name)

    drift = compose_drift or image_drift or not_running
    payload = {
        "compose_path": a.compose_path,
        "compose_drift": compose_drift,
        "image_drift": image_drift,
        "image_current": current_image,
        "image_desired": desired_image,
        "not_running": not_running,
    }
    if not drift:
        return _emit("no-change", {}, a.check)
    if a.check:
        return _emit("would-change", payload, True)

    # Ensure the compose dir exists (the FileStation-tracked terraform
    # resource creates it, but be defensive on a fresh box).
    os.makedirs(os.path.dirname(a.compose_path), exist_ok=True)
    if compose_drift:
        _atomic_write(a.compose_path, desired_compose, 0o644)

    # docker compose up -d will pull the new image if the tag differs and
    # recreate the container on config / image / mount changes.
    r = _run("docker", "compose", "-f", a.compose_path, "up", "-d")
    if r.returncode != 0:
        return _fail(
            {
                "reason": "docker compose up failed",
                "stdout": r.stdout,
                "stderr": r.stderr,
                "payload": payload,
            }
        )
    payload["compose_out"] = r.stderr.strip() or r.stdout.strip()
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# layout — bootstrap a single-node garage cluster's layout once
# ---------------------------------------------------------------------------
_LAYOUT_VER_RE = re.compile(r"Current cluster layout version:\s*(\d+)")


def _garage(container, *cmd):
    # dxflrs/garage is a FROM-scratch image with the binary at `/garage` and
    # no PATH set, so `docker exec <ct> garage …` fails with "executable file
    # not found in $PATH". Absolute path is the robust call.
    return _run("docker", "exec", container, "/garage", *cmd)


# How long to wait for a just-started Garage to accept RPC before giving up.
GARAGE_READY_TIMEOUT = 90.0
GARAGE_READY_INTERVAL = 3.0


def _garage_status_ready(container, timeout=GARAGE_READY_TIMEOUT, interval=GARAGE_READY_INTERVAL):
    """Poll `garage status` until the daemon accepts RPC, or `timeout` elapses.

    `docker compose up -d` (the `deploy` subcommand) returns as soon as the
    container is CREATED — Garage still needs a few seconds to open its RPC
    socket on :3901. Calling `status` immediately therefore races the daemon and
    fails with "Connection refused (os error 111)".

    That race took the fleet deploy red on 2026-07-20: an e4e-nas reboot made
    the container drift, `deploy` recreated it, and `layout` ran ONE SECOND
    later against a daemon that wasn't listening yet. Nothing was actually
    wrong — a re-run minutes later passed untouched.

    Returns the last CompletedProcess, so the caller keeps its existing
    success/failure handling (and its stdout/stderr for the failure payload).
    """
    deadline = time.monotonic() + timeout
    while True:
        r = _garage(container, "status")
        if r.returncode == 0 or time.monotonic() + interval >= deadline:
            return r
        time.sleep(interval)


def do_layout(a):
    # 1. Daemon up + RPC responsive? On --check mode the container may not
    #    exist yet (preview on a fresh box); report a planned change rather
    #    than failing the dry run.
    #
    # A real apply WAITS for readiness (the container may have just been
    # recreated by `deploy`); --check does a single probe so dry runs stay fast
    # and never block for 90s on a box where Garage isn't running at all.
    r = _garage(a.container_name, "status") if a.check else _garage_status_ready(a.container_name)
    if r.returncode != 0:
        if a.check:
            return _emit(
                "would-change",
                {
                    "reason": "container not yet running — would assign layout once it's up",
                    "zone": a.zone,
                    "capacity": a.capacity,
                },
                True,
            )
        return _fail(
            {
                "reason": "`garage status` failed — container not ready",
                "stdout": r.stdout,
                "stderr": r.stderr,
            }
        )

    # 2. Is a layout already defined? (version > 0 means yes.)
    r = _garage(a.container_name, "layout", "show")
    if r.returncode != 0:
        return _fail(
            {"reason": "`garage layout show` failed", "stdout": r.stdout, "stderr": r.stderr}
        )
    show = r.stdout
    m = _LAYOUT_VER_RE.search(show)
    version = int(m.group(1)) if m else 0
    if version > 0:
        # Anti-rebalance guard: don't auto-reassign. If the spec capacity /
        # zone has drifted from the active layout, the operator must do the
        # rebalance explicitly (a real-data-movement event, not a sync).
        return _emit("no-change", {}, a.check)

    # 3. Pull our node ID from `garage status` (HEALTHY NODES table; first
    #    column is the node id — currently 16 hex chars in v1.x output, but
    #    truncate defensively in case a future release prints the full 64.
    #    `garage layout assign` accepts either form, so feeding the 16-char
    #    short id is fine either way.)
    status = _garage(a.container_name, "status").stdout
    node_id = None
    for line in status.splitlines():
        line = line.strip()
        # Skip headers / separators / capacity tables — match a leading
        # hex run of >= 16 chars (covers both short and full forms).
        parts = line.split()
        if parts and re.fullmatch(r"[0-9a-fA-F]{16,}", parts[0]):
            node_id = parts[0][:16]
            break
    if not node_id:
        return _fail({"reason": "couldn't parse node id from `garage status`", "stdout": status})

    payload = {
        "node_id": node_id,
        "zone": a.zone,
        "capacity": a.capacity,
        "version": 1,
    }
    if a.check:
        return _emit("would-change", payload, True)

    # 4. Assign + apply. layout apply --version <new_version>; first apply is 1.
    r = _garage(a.container_name, "layout", "assign", "-z", a.zone, "-c", a.capacity, node_id)
    if r.returncode != 0:
        return _fail(
            {
                "reason": "`garage layout assign` failed",
                "stdout": r.stdout,
                "stderr": r.stderr,
                "payload": payload,
            }
        )
    r = _garage(a.container_name, "layout", "apply", "--version", "1")
    if r.returncode != 0:
        return _fail(
            {
                "reason": "`garage layout apply` failed",
                "stdout": r.stdout,
                "stderr": r.stderr,
                "payload": payload,
            }
        )
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# Garage v2 Admin API — used by sync-buckets / sync-keys instead of shelling
# out to `garage bucket ...` / `garage key ...` text output (unlike `layout`,
# which predates the v2 admin API and still parses CLI text). The admin API
# is JSON, versioned, and documented (garagehq.deuxfleurs.fr admin-api); the
# CLI is a thin wrapper over the same calls. Reachable on loopback because
# the garage container runs with network_mode: host, same as garage-ui's own
# admin_endpoint (see GARAGE_UI_CONFIG_TEMPLATE above).
# ---------------------------------------------------------------------------
def _admin_request(admin_port, admin_token, method, path, query=None, body=None):
    """POST/GET the Garage admin API. Returns (http_status, parsed_json) for
    ANY http-level response (including 4xx/5xx) so callers can report a
    structured FAIL instead of catching an exception. Only genuine transport
    failures (connection refused, DNS, timeout) raise — callers wrap those."""
    url = "http://127.0.0.1:%d%s" % (admin_port, path)
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + admin_token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = {"raw": raw.decode("utf-8", "replace")}
        return e.code, parsed


_PERM_FLAGS = ("read", "write", "owner")


def _permissions_dict(perm_list):
    bad = [p for p in perm_list if p not in _PERM_FLAGS]
    if bad:
        raise ValueError("invalid permission(s) %s (valid: %s)" % (bad, list(_PERM_FLAGS)))
    return {p: (p in perm_list) for p in _PERM_FLAGS}


# ---------------------------------------------------------------------------
# sync-buckets — create-if-missing buckets (Admin API: ListBuckets/CreateBucket)
# ---------------------------------------------------------------------------
def do_sync_buckets(a):
    admin_token = os.environ.get("GARAGE_ADMIN_TOKEN", "")
    if not admin_token:
        return _fail({"reason": "required secret env var unset", "vars": ["GARAGE_ADMIN_TOKEN"]})
    try:
        desired_names = json.loads(a.buckets_json)
    except ValueError as e:
        return _fail({"reason": "invalid --buckets-json", "error": str(e)})

    admin_port = int(a.admin_port)
    try:
        status, buckets = _admin_request(admin_port, admin_token, "GET", "/v2/ListBuckets")
    except (urllib.error.URLError, OSError) as e:
        return _fail({"reason": "ListBuckets request failed", "error": str(e)})
    if status != 200:
        return _fail({"reason": "ListBuckets returned non-200", "status": status, "body": buckets})

    existing_aliases = set()
    for b in buckets:
        existing_aliases.update(b.get("globalAliases") or [])

    missing = [n for n in desired_names if n not in existing_aliases]
    payload = {"buckets_to_create": missing}
    if not missing:
        return _emit("no-change", {}, a.check)
    if a.check:
        return _emit("would-change", payload, True)

    for name in missing:
        status, resp = _admin_request(
            admin_port, admin_token, "POST", "/v2/CreateBucket", body={"globalAlias": name}
        )
        if status not in (200, 201):
            return _fail(
                {"reason": "CreateBucket failed", "bucket": name, "status": status, "body": resp}
            )
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# sync-keys — import-if-missing keys from OpenBao-provisioned credentials +
# converge per-bucket read/write/owner grants (Admin API: ListKeys / ImportKey /
# GetBucketInfo / AllowBucketKey / DenyBucketKey). OpenBao is source of truth; the
# <name>.env on the NAS is a render of it, so a lost keys_dir is recoverable (#75).
# ---------------------------------------------------------------------------
def do_sync_keys(a):
    admin_token = os.environ.get("GARAGE_ADMIN_TOKEN", "")
    if not admin_token:
        return _fail({"reason": "required secret env var unset", "vars": ["GARAGE_ADMIN_TOKEN"]})
    admin_port = int(a.admin_port)

    try:
        desired_keys = json.loads(a.keys_json)
    except ValueError as e:
        return _fail({"reason": "invalid --keys-json", "error": str(e)})

    # Per-key credentials the control node provisioned in OpenBao (secret/e4e-nas/
    # garage-keys/<name>) and passed in via GARAGE_KEY_CREDENTIALS_JSON — env, NOT
    # argv (same discipline as GARAGE_ADMIN_TOKEN). OpenBao is the source of truth:
    # keys are IMPORTED with these creds rather than server-generated, and the
    # on-NAS <name>.env is only a render of them — so a lost keys_dir is always
    # recoverable (the old unrecoverable-drift FAIL is gone). See README "Secrets"
    # and #75. Shape: {"<name>": {"access_key_id": "...", "secret_access_key": "..."}}.
    creds_raw = os.environ.get("GARAGE_KEY_CREDENTIALS_JSON", "")
    if not creds_raw:
        return _fail(
            {"reason": "required secret env var unset", "vars": ["GARAGE_KEY_CREDENTIALS_JSON"]}
        )
    try:
        key_creds = json.loads(creds_raw)
    except ValueError as e:
        return _fail({"reason": "invalid GARAGE_KEY_CREDENTIALS_JSON", "error": str(e)})

    # Every declared key must have a complete credential supplied. The control
    # node create-once-provisions these, so a gap means a provisioning / policy
    # problem upstream — fail loudly rather than import a half-key.
    missing_cred = [
        kspec["name"]
        for kspec in desired_keys
        if not (key_creds.get(kspec["name"]) or {}).get("access_key_id")
        or not (key_creds.get(kspec["name"]) or {}).get("secret_access_key")
    ]
    if missing_cred:
        return _fail(
            {
                "reason": "no credential supplied in GARAGE_KEY_CREDENTIALS_JSON for key(s) — "
                "the control node must provision secret/e4e-nas/garage-keys/<name> before "
                "sync-keys (see deploy/deploy-ansible.sh)",
                "keys": missing_cred,
            }
        )

    try:
        for kspec in desired_keys:
            for bspec in kspec.get("buckets", []):
                _permissions_dict(bspec.get("permissions", []))
    except ValueError as e:
        return _fail({"reason": str(e)})

    try:
        status, buckets = _admin_request(admin_port, admin_token, "GET", "/v2/ListBuckets")
    except (urllib.error.URLError, OSError) as e:
        return _fail({"reason": "ListBuckets request failed", "error": str(e)})
    if status != 200:
        return _fail({"reason": "ListBuckets returned non-200", "status": status, "body": buckets})
    bucket_id_by_alias = {}
    for b in buckets:
        for alias in b.get("globalAliases") or []:
            bucket_id_by_alias[alias] = b["id"]

    for kspec in desired_keys:
        for bspec in kspec.get("buckets", []):
            if bspec["name"] not in bucket_id_by_alias:
                return _fail(
                    {
                        "reason": "bucket not found on Garage — sync-buckets must run "
                        "before sync-keys (task ordering)",
                        "key": kspec["name"],
                        "bucket": bspec["name"],
                    }
                )

    try:
        status, keys = _admin_request(admin_port, admin_token, "GET", "/v2/ListKeys")
    except (urllib.error.URLError, OSError) as e:
        return _fail({"reason": "ListKeys request failed", "error": str(e)})
    if status != 200:
        return _fail({"reason": "ListKeys returned non-200", "status": status, "body": keys})
    key_id_by_name = {}
    for k in keys:
        name = k.get("name")
        if name in key_id_by_name:
            return _fail(
                {
                    "reason": "duplicate Garage key name — can't manage declaratively; "
                    "rename or delete the duplicate on the box first",
                    "name": name,
                }
            )
        key_id_by_name[name] = k["id"]

    def secret_path(name):
        return os.path.join(a.keys_dir, name + ".env")

    def env_body(name):
        c = key_creds[name]
        return "ACCESS_KEY_ID=%s\nSECRET_ACCESS_KEY=%s\n" % (
            c["access_key_id"],
            c["secret_access_key"],
        )

    # Keys not yet on Garage are IMPORTED with the OpenBao-provisioned creds
    # (POST /v2/ImportKey — accessKeyId/secretAccessKey in the JSON body, never
    # argv). A key already on Garage must match the id OpenBao holds; a mismatch
    # is out-of-band drift (someone rotated the key without updating OpenBao) and
    # is surfaced, not silently reconciled — same philosophy as the layout
    # anti-rebalance guard.
    to_import = [k["name"] for k in desired_keys if k["name"] not in key_id_by_name]
    id_mismatch = [
        {"key": k["name"], "on_garage": key_id_by_name[k["name"]], "in_openbao": want}
        for k in desired_keys
        for want in [key_creds[k["name"]]["access_key_id"]]
        if k["name"] in key_id_by_name and key_id_by_name[k["name"]] != want
    ]
    if id_mismatch:
        return _fail(
            {
                "reason": "key(s) exist on Garage with a different access key id than OpenBao "
                "holds — out-of-band rotation. Reconcile by deleting the key on Garage "
                "(`docker exec garage /garage key delete <id>`) and re-running (re-imports the "
                "OpenBao credential), or update OpenBao to match the live id.",
                "keys": id_mismatch,
            }
        )

    # The <name>.env is a render of OpenBao truth: (re)write any that is missing
    # or stale (_read returns None for an absent file). This restores a wiped
    # keys_dir with NO rotation — the failure mode that used to be unrecoverable.
    env_to_write = [
        k["name"] for k in desired_keys if _read(secret_path(k["name"])) != env_body(k["name"])
    ]

    # Diff every declared key x bucket grant against the bucket's current
    # per-key permissions. Not-yet-imported keys have no current grants by
    # definition, so everything desired-true becomes an "allow".
    grant_ops = []  # (key_name, bucket_name, bucket_id, op, perms_dict)
    for kspec in desired_keys:
        name = kspec["name"]
        key_id = key_id_by_name.get(name)
        for bspec in kspec.get("buckets", []):
            desired_perms = _permissions_dict(bspec.get("permissions", []))
            bucket_id = bucket_id_by_alias[bspec["name"]]
            current_perms = {"read": False, "write": False, "owner": False}
            if key_id is not None:
                status, info = _admin_request(
                    admin_port, admin_token, "GET", "/v2/GetBucketInfo", query={"id": bucket_id}
                )
                if status != 200:
                    return _fail(
                        {
                            "reason": "GetBucketInfo failed",
                            "bucket": bspec["name"],
                            "status": status,
                            "body": info,
                        }
                    )
                for kperm in info.get("keys", []) or []:
                    if kperm.get("accessKeyId") == key_id:
                        p = kperm.get("permissions") or {}
                        current_perms = {f: bool(p.get(f)) for f in _PERM_FLAGS}
                        break
            to_allow = {f: True for f in _PERM_FLAGS if desired_perms[f] and not current_perms[f]}
            to_deny = {f: True for f in _PERM_FLAGS if current_perms[f] and not desired_perms[f]}
            if to_allow:
                grant_ops.append((name, bspec["name"], bucket_id, "allow", to_allow))
            if to_deny:
                grant_ops.append((name, bspec["name"], bucket_id, "deny", to_deny))

    changed = bool(to_import or env_to_write or grant_ops)
    payload = {
        "keys_to_import": to_import,
        "env_to_write": env_to_write,
        "grant_ops": [
            {"key": kn, "bucket": bn, "op": op, "permissions": sorted(f for f in p)}
            for kn, bn, _bid, op, p in grant_ops
        ],
    }
    if not changed:
        return _emit("no-change", {}, a.check)
    if a.check:
        return _emit("would-change", payload, True)

    os.makedirs(a.keys_dir, exist_ok=True)
    for name in to_import:
        c = key_creds[name]
        status, resp = _admin_request(
            admin_port,
            admin_token,
            "POST",
            "/v2/ImportKey",
            body={
                "accessKeyId": c["access_key_id"],
                "secretAccessKey": c["secret_access_key"],
                "name": name,
            },
        )
        if status not in (200, 201):
            return _fail(
                {"reason": "ImportKey failed", "key": name, "status": status, "body": resp}
            )
        key_id_by_name[name] = c["access_key_id"]

    # Render the <name>.env cache from OpenBao truth (imported keys + any that
    # drifted / went missing). Secrets go through the env, never the payload.
    for name in env_to_write:
        _atomic_write(secret_path(name), env_body(name), 0o400)

    for key_name, bucket_name, bucket_id, op, perms in grant_ops:
        key_id = key_id_by_name[key_name]
        path = "/v2/AllowBucketKey" if op == "allow" else "/v2/DenyBucketKey"
        status, resp = _admin_request(
            admin_port,
            admin_token,
            "POST",
            path,
            body={"bucketId": bucket_id, "accessKeyId": key_id, "permissions": perms},
        )
        if status != 200:
            return _fail(
                {
                    "reason": "%s failed" % path,
                    "key": key_name,
                    "bucket": bucket_name,
                    "status": status,
                    "body": resp,
                }
            )

    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# render-ui-config — write garage-ui's config.yaml (OIDC + admin_token)
# ---------------------------------------------------------------------------
# JWT private key persistence: garage-ui can auto-generate an Ed25519 key on
# startup, but every restart invalidates all sessions ("If not specified, a
# new key will be generated on each startup (tokens won't persist across
# restarts)" — upstream config.example.yaml). Generate once + persist next
# to the config file so user logins survive container restarts + image bumps.
_JWT_KEY_FILENAME = "jwt-key.pem"
_UI_SECRET_ENV_VAR = "GARAGE_UI_OIDC_CLIENT_SECRET"

# The noooste/garage-ui image runs as USER garageui (UID/GID 1000). config.yaml
# carries secrets (OIDC client_secret, admin token, JWT key) so it's mode 0400 —
# own it by the container's UID so the NON-ROOT container can read it (instead of
# escalating the container to root). On DSM no real account is UID 1000 (DSM users
# start ≥ 1026), so on the host the file stays effectively root-only. If a future
# garage-ui image changes this UID, the container will fail "permission denied" on
# config.yaml — update these to match the image's `USER`.
_GARAGE_UI_UID = 1000
_GARAGE_UI_GID = 1000


def _ensure_jwt_key(config_path):
    """Generate an Ed25519 PEM key next to the config if not present.
    Returns the PEM content (multi-line) for inline embedding in YAML."""
    key_path = os.path.join(os.path.dirname(config_path), _JWT_KEY_FILENAME)
    if not os.path.exists(key_path):
        os.makedirs(os.path.dirname(key_path), exist_ok=True)
        r = _run("openssl", "genpkey", "-algorithm", "ED25519", "-out", key_path)
        if r.returncode != 0:
            raise RuntimeError("openssl genpkey ED25519 failed: " + (r.stderr or r.stdout))
        os.chmod(key_path, 0o400)
        os.chown(key_path, 0, 0)
    with open(key_path, "r") as fh:
        return fh.read()


def _yaml_list_lines(items, indent):
    """Render a Python list as YAML list items at `indent` columns. Each
    item is double-quoted; rejects `"`, `\\n`, `\\r` to defend the literal."""
    pad = " " * indent
    out = []
    for v in items:
        s = str(v)
        if '"' in s or "\n" in s or "\r" in s:
            raise ValueError("YAML list item contains unescaped quote or newline: " + s)
        out.append('%s- "%s"' % (pad, s))
    return "\n".join(out)


def do_render_ui_config(a):
    # OIDC client_secret comes from env (NOT argv — same rationale as the
    # cluster secrets: kept out of /proc/<pid>/cmdline and `ps`).
    oidc_client_secret = os.environ.get(_UI_SECRET_ENV_VAR, "")
    if not oidc_client_secret:
        return _fail({"reason": "required secret env var unset", "vars": [_UI_SECRET_ENV_VAR]})

    # admin_token reuse: read from GARAGE_ADMIN_TOKEN env (already required
    # by render-config). Same secret, same source, no duplication.
    garage_admin_token = os.environ.get("GARAGE_ADMIN_TOKEN", "")
    if not garage_admin_token:
        return _fail({"reason": "required secret env var unset", "vars": ["GARAGE_ADMIN_TOKEN"]})

    str_fields = {
        "bind_host": a.bind_host,
        "public_hostname": a.public_hostname,
        "public_url": a.public_url,
        "garage_region": a.garage_region,
        "garage_admin_token": garage_admin_token,
        "oidc_provider_name": a.oidc_provider_name,
        "oidc_client_id": a.oidc_client_id,
        "oidc_client_secret": oidc_client_secret,
        "oidc_issuer_url": a.oidc_issuer_url,
        "oidc_role_attribute_path": a.oidc_role_attribute_path,
    }
    # Same TOML/YAML injection defense as the garage.toml render: reject
    # raw `"`, `\n`, `\r` in any string-typed field.
    for k, v in str_fields.items():
        if isinstance(v, str) and ('"' in v or "\n" in v or "\r" in v):
            return _fail({"reason": "field contains unescaped quote or newline", "field": k})

    scopes = json.loads(a.oidc_scopes_json)
    admin_roles = json.loads(a.oidc_admin_roles_json)
    if not admin_roles:
        return _fail({"reason": "ui.oidc.admin_roles must list at least one role"})

    key_path = os.path.join(os.path.dirname(a.config_path), _JWT_KEY_FILENAME)
    key_missing = not os.path.exists(key_path)
    if key_missing and not a.check:
        _ensure_jwt_key(a.config_path)
        jwt_pem = _read(key_path).rstrip()
    elif key_missing and a.check:
        jwt_pem = "<would-generate-on-apply>"
    else:
        jwt_pem = _read(key_path).rstrip()

    fields = {
        "bind_host": a.bind_host,
        "port": int(a.port),
        "public_hostname": a.public_hostname,
        "public_url": a.public_url,
        "garage_s3_port": int(a.garage_s3_port),
        "garage_admin_port": int(a.garage_admin_port),
        "garage_region": a.garage_region,
        "garage_admin_token": garage_admin_token,
        "jwt_private_key": jwt_pem.replace("\n", "\\n"),
        "oidc_provider_name": a.oidc_provider_name,
        "oidc_client_id": a.oidc_client_id,
        "oidc_client_secret": oidc_client_secret,
        "oidc_issuer_url": a.oidc_issuer_url,
        "oidc_role_attribute_path": a.oidc_role_attribute_path,
        "oidc_scopes_yaml": _yaml_list_lines(scopes, 6),
        "oidc_admin_roles_yaml": _yaml_list_lines(admin_roles, 6),
    }
    desired = GARAGE_UI_CONFIG_TEMPLATE % fields
    desired_hash = _sha256(desired)
    current = _read(a.config_path)
    current_hash = _sha256(current) if current is not None else None

    # Ownership is part of "correct" here: the file is 0400 and must be owned by
    # the garage-ui container UID (else the non-root container can't read it — a
    # prior render as root:root would otherwise stick forever on content-match).
    # Treat an owner mismatch as drift so the role re-asserts it (self-heals on
    # the next run / nightly converge). stat failure (missing file) → not-owned.
    try:
        owner_ok = os.stat(a.config_path).st_uid == _GARAGE_UI_UID
    except OSError:
        owner_ok = False

    if current_hash == desired_hash and not key_missing and owner_ok:
        return _emit("no-change", {}, a.check)

    payload = {
        "config_path": a.config_path,
        "jwt_key_path": key_path,
        "key_generated": key_missing,
        "had_existing": current is not None,
        "desired_sha256": desired_hash,
    }
    if a.check:
        return _emit("would-change", payload, True)

    # Owned by the garage-ui container UID (not root) so the non-root container
    # reads its own 0400 config — see _GARAGE_UI_UID.
    _atomic_write(a.config_path, desired, 0o400, _GARAGE_UI_UID, _GARAGE_UI_GID)
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# deploy-ui — render compose + `docker compose up -d` on drift
# ---------------------------------------------------------------------------
def do_deploy_ui(a):
    fields = {
        "container_name": a.container_name,
        "image": a.image,
        "image_tag": a.image_tag,
        "config_path": a.config_path,
    }
    desired_compose = GARAGE_UI_COMPOSE_TEMPLATE % fields
    current_compose = _read(a.compose_path)

    config_missing = not os.path.exists(a.config_path)
    if config_missing:
        if not a.check:
            return _fail(
                {
                    "reason": "garage-ui config.yaml missing — run render-ui-config first",
                    "config_path": a.config_path,
                }
            )
        return _emit(
            "would-change",
            {
                "compose_path": a.compose_path,
                "config_missing": True,
                "reason": "render-ui-config must run before deploy-ui on apply",
            },
            True,
        )

    desired_image = "%s:%s" % (a.image, a.image_tag)
    compose_drift = current_compose != desired_compose
    current_image = _container_image(a.container_name)
    image_drift = current_image != desired_image
    not_running = not _container_running(a.container_name)
    # config.yaml is a read-only bind mount that garage-ui parses ONCE at
    # startup. A plain `docker compose up -d` will NOT restart a running,
    # otherwise-unchanged container just because that file's contents changed —
    # so a config-only edit (e.g. updated admin_roles) would never take effect.
    # render-ui-config reports whether it rewrote the file; the task threads that
    # status in via --config-changed so we restart the container to reload it.
    config_changed = a.config_changed

    recreate = compose_drift or image_drift or not_running
    drift = recreate or config_changed
    payload = {
        "compose_path": a.compose_path,
        "compose_drift": compose_drift,
        "image_drift": image_drift,
        "image_current": current_image,
        "image_desired": desired_image,
        "not_running": not_running,
        "config_changed": config_changed,
    }
    if not drift:
        return _emit("no-change", {}, a.check)
    if a.check:
        return _emit("would-change", payload, True)

    os.makedirs(os.path.dirname(a.compose_path), exist_ok=True)
    if compose_drift:
        _atomic_write(a.compose_path, desired_compose, 0o644)

    # `up -d` creates/recreates on compose/image drift or when stopped; when the
    # ONLY drift is the config file, the container is already up-to-date by
    # compose's reckoning, so restart it explicitly to re-read config.yaml.
    if recreate:
        r = _run("docker", "compose", "-f", a.compose_path, "up", "-d")
        op = "up"
    else:
        r = _run("docker", "compose", "-f", a.compose_path, "restart")
        op = "restart"
    if r.returncode != 0:
        return _fail(
            {
                "reason": "docker compose %s failed" % op,
                "stdout": r.stdout,
                "stderr": r.stderr,
                "payload": payload,
            }
        )
    payload["compose_out"] = r.stderr.strip() or r.stdout.strip()
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    rc = sub.add_parser("render-config")
    rc.add_argument("--config-path", required=True)
    rc.add_argument("--db-engine", required=True)
    rc.add_argument("--replication-factor", required=True)
    rc.add_argument("--compression-level", required=True)
    rc.add_argument("--rpc-bind-addr", required=True)
    rc.add_argument("--rpc-public-addr", required=True)
    rc.add_argument("--s3-api-bind-addr", required=True)
    rc.add_argument("--s3-region", required=True)
    rc.add_argument("--s3-root-domain", required=True)
    rc.add_argument("--s3-web-bind-addr", required=True)
    rc.add_argument("--s3-web-root-domain", required=True)
    rc.add_argument("--s3-web-index", required=True)
    rc.add_argument("--admin-api-bind-addr", required=True)
    # Secrets read from os.environ — NOT argv (avoids `ps`/`top` exposure).
    # See _SECRET_ENV_VARS + the render-config docstring at the top.
    rc.add_argument(
        "--meta-dir", required=True
    )  # accepted for tasks/main.yml symmetry; not used by template
    rc.add_argument("--data-dir", required=True)
    rc.add_argument("--check", action="store_true")
    rc.set_defaults(fn=do_render_config)

    dp = sub.add_parser("deploy")
    dp.add_argument(
        "--compose-path",
        required=True,
        help="Absolute on-disk path for docker-compose.yml "
        "(e.g. /volume2/docker/garage/docker-compose.yml). "
        "Driven from the spec — no implicit volume mapping.",
    )
    dp.add_argument("--container-name", required=True)
    dp.add_argument("--image", required=True)
    dp.add_argument("--image-tag", required=True)
    dp.add_argument("--network-mode", required=True)
    dp.add_argument("--restart-policy", required=True)
    dp.add_argument("--meta-dir", required=True)
    dp.add_argument("--data-dir", required=True)
    dp.add_argument("--config-path", required=True)
    dp.add_argument("--rust-log", required=True)
    dp.add_argument("--check", action="store_true")
    dp.set_defaults(fn=do_deploy)

    ly = sub.add_parser("layout")
    ly.add_argument("--container-name", required=True)
    ly.add_argument("--zone", required=True)
    ly.add_argument("--capacity", required=True)
    ly.add_argument("--check", action="store_true")
    ly.set_defaults(fn=do_layout)

    sb = sub.add_parser("sync-buckets")
    sb.add_argument("--admin-port", required=True)
    sb.add_argument(
        "--buckets-json",
        required=True,
        help='JSON array of bucket (global alias) names, e.g. ["label-studio"]',
    )
    # Admin token read from GARAGE_ADMIN_TOKEN env — NOT argv. See do_sync_buckets.
    sb.add_argument("--check", action="store_true")
    sb.set_defaults(fn=do_sync_buckets)

    sk = sub.add_parser("sync-keys")
    sk.add_argument("--admin-port", required=True)
    sk.add_argument(
        "--keys-json",
        required=True,
        help='JSON array: [{"name":"label-studio","buckets":'
        '[{"name":"label-studio","permissions":["read","write"]}]}]',
    )
    sk.add_argument(
        "--keys-dir",
        required=True,
        help="Directory where each newly-created key's one-time secret is "
        "persisted as <name>.env (root:root 0400).",
    )
    # Admin token read from GARAGE_ADMIN_TOKEN env — NOT argv. See do_sync_keys.
    sk.add_argument("--check", action="store_true")
    sk.set_defaults(fn=do_sync_keys)

    ru = sub.add_parser("render-ui-config")
    ru.add_argument("--config-path", required=True)
    ru.add_argument("--bind-host", required=True)
    ru.add_argument("--port", required=True)
    ru.add_argument("--public-hostname", required=True)
    ru.add_argument(
        "--public-url",
        required=True,
        help="Public root URL (e.g. https://s3-admin.e4e.ucsd.edu); "
        "becomes server.root_url + OIDC callback root",
    )
    ru.add_argument("--garage-s3-port", required=True)
    ru.add_argument("--garage-admin-port", required=True)
    ru.add_argument("--garage-region", required=True)
    ru.add_argument("--oidc-provider-name", required=True)
    ru.add_argument("--oidc-client-id", required=True)
    # OIDC client_secret + admin_token come from env (NOT argv). See do_render_ui_config.
    ru.add_argument("--oidc-issuer-url", required=True)
    ru.add_argument("--oidc-role-attribute-path", required=True)
    ru.add_argument(
        "--oidc-scopes-json",
        required=True,
        help='JSON array of scope strings, e.g. ["openid","email"]',
    )
    ru.add_argument(
        "--oidc-admin-roles-json",
        required=True,
        help="JSON array of admin role strings (≥ 1 required)",
    )
    ru.add_argument("--check", action="store_true")
    ru.set_defaults(fn=do_render_ui_config)

    du = sub.add_parser("deploy-ui")
    du.add_argument("--compose-path", required=True)
    du.add_argument("--container-name", required=True)
    du.add_argument("--image", required=True)
    du.add_argument("--image-tag", required=True)
    du.add_argument("--config-path", required=True)
    # render-ui-config rewrote config.yaml this run → restart to reload it
    # (garage-ui reads config only at startup; `up -d` alone won't restart).
    du.add_argument("--config-changed", action="store_true")
    du.add_argument("--check", action="store_true")
    du.set_defaults(fn=do_deploy_ui)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
