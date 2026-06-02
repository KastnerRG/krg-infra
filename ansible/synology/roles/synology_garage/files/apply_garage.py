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
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile


# DSM Container Manager ships docker under non-standard paths that sudo's
# secure_path doesn't include — `docker` is invisible to subprocess unless we
# prepend the install locations. Adding both v7.2+ (Container Manager) and
# legacy (Docker package) targets so this works across DSM versions.
_DSM_DOCKER_PATHS = (
    "/usr/local/bin",                                  # symlink target on most DSM 7.x
    "/var/packages/ContainerManager/target/usr/bin",   # DSM 7.2+ Container Manager
    "/var/packages/Docker/target/usr/bin",             # legacy DSM ≤ 7.1 Docker package
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
            args=list(cmd), returncode=127, stdout="",
            stderr="binary not found on PATH: " + (cmd[0] if cmd else "<empty>") +
                   " (" + str(e) + ")",
        )


def _sha256(content):
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def _read(path):
    try:
        with open(path, "r") as fh:
            return fh.read()
    except (FileNotFoundError, IsADirectoryError):
        return None


def _atomic_write(path, content, mode):
    """Write `content` to `path` via tmp+rename; chmod+chown root:root.
    Same dir as the target so rename is atomic on the same filesystem."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".krg-", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        os.chmod(tmp, mode)
        os.chown(tmp, 0, 0)
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
        return _fail({"reason": "required secret env vars unset",
                      "vars": missing})
    fields = {
        "db_engine":           a.db_engine,
        "replication_factor":  int(a.replication_factor),
        "compression_level":   int(a.compression_level),
        "rpc_bind_addr":       a.rpc_bind_addr,
        "rpc_public_addr":     a.rpc_public_addr,
        "rpc_secret":          os.environ["GARAGE_RPC_SECRET"],
        "s3_api_bind_addr":    a.s3_api_bind_addr,
        "s3_region":           a.s3_region,
        "s3_root_domain":      a.s3_root_domain,
        "s3_web_bind_addr":    a.s3_web_bind_addr,
        "s3_web_root_domain":  a.s3_web_root_domain,
        "s3_web_index":        a.s3_web_index,
        "admin_api_bind_addr": a.admin_api_bind_addr,
        "admin_token":         os.environ["GARAGE_ADMIN_TOKEN"],
        "metrics_token":       os.environ["GARAGE_METRICS_TOKEN"],
    }
    # Reject any literal `"`, `\n`, or `\r` in a string field — these
    # would close the TOML basic-string literal early and inject content
    # (basic strings can't contain raw newlines either). Cheap defense at
    # the bottleneck; the template uses double-quoted basic strings only,
    # no triple-quoted blocks.
    for k, v in fields.items():
        if isinstance(v, str) and ('"' in v or "\n" in v or "\r" in v):
            return _fail({"reason": "field contains unescaped quote or newline",
                          "field": k})

    desired = GARAGE_TOML_TEMPLATE % fields
    desired_hash = _sha256(desired)
    current = _read(a.config_path)
    current_hash = _sha256(current) if current is not None else None

    if current_hash == desired_hash:
        return _emit("no-change", {}, a.check)

    # No secret values in the payload — only the fact that secrets-bearing
    # content changed. Keep no_log honest even if the operator forgot.
    payload = {
        "config_path":     a.config_path,
        "had_existing":    current is not None,
        "desired_sha256":  desired_hash,
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
        "container_name":  a.container_name,
        "image":           a.image,
        "image_tag":       a.image_tag,
        "network_mode":    a.network_mode,
        "restart_policy":  a.restart_policy,
        "rust_log":        a.rust_log,
        "meta_dir":        a.meta_dir,
        "data_dir":        a.data_dir,
        "config_path":     a.config_path,
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
            return _fail({"reason": "garage.toml missing — run render-config first",
                          "config_path": a.config_path})
        return _emit("would-change", {
            "compose_path":   a.compose_path,
            "config_missing": True,
            "reason":         "render-config must run before deploy on apply",
        }, True)

    desired_image = "%s:%s" % (a.image, a.image_tag)
    compose_drift = (current_compose != desired_compose)
    current_image = _container_image(a.container_name)
    image_drift = (current_image != desired_image)
    not_running = not _container_running(a.container_name)

    drift = compose_drift or image_drift or not_running
    payload = {
        "compose_path":  a.compose_path,
        "compose_drift": compose_drift,
        "image_drift":   image_drift,
        "image_current": current_image,
        "image_desired": desired_image,
        "not_running":   not_running,
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
        return _fail({"reason":  "docker compose up failed",
                      "stdout":  r.stdout, "stderr": r.stderr,
                      "payload": payload})
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


def do_layout(a):
    # 1. Daemon up + RPC responsive? On --check mode the container may not
    #    exist yet (preview on a fresh box); report a planned change rather
    #    than failing the dry run.
    r = _garage(a.container_name, "status")
    if r.returncode != 0:
        if a.check:
            return _emit("would-change", {
                "reason":   "container not yet running — would assign layout once it's up",
                "zone":     a.zone,
                "capacity": a.capacity,
            }, True)
        return _fail({"reason":  "`garage status` failed — container not ready",
                      "stdout":  r.stdout, "stderr": r.stderr})

    # 2. Is a layout already defined? (version > 0 means yes.)
    r = _garage(a.container_name, "layout", "show")
    if r.returncode != 0:
        return _fail({"reason":  "`garage layout show` failed",
                      "stdout":  r.stdout, "stderr": r.stderr})
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
        return _fail({"reason":  "couldn't parse node id from `garage status`",
                      "stdout":  status})

    payload = {
        "node_id":  node_id,
        "zone":     a.zone,
        "capacity": a.capacity,
        "version":  1,
    }
    if a.check:
        return _emit("would-change", payload, True)

    # 4. Assign + apply. layout apply --version <new_version>; first apply is 1.
    r = _garage(a.container_name, "layout", "assign",
                "-z", a.zone, "-c", a.capacity, node_id)
    if r.returncode != 0:
        return _fail({"reason":  "`garage layout assign` failed",
                      "stdout":  r.stdout, "stderr": r.stderr, "payload": payload})
    r = _garage(a.container_name, "layout", "apply", "--version", "1")
    if r.returncode != 0:
        return _fail({"reason":  "`garage layout apply` failed",
                      "stdout":  r.stdout, "stderr": r.stderr, "payload": payload})
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
    rc.add_argument("--meta-dir", required=True)   # accepted for tasks/main.yml symmetry; not used by template
    rc.add_argument("--data-dir", required=True)
    rc.add_argument("--check", action="store_true")
    rc.set_defaults(fn=do_render_config)

    dp = sub.add_parser("deploy")
    dp.add_argument("--compose-path", required=True,
                    help="Absolute on-disk path for docker-compose.yml "
                         "(e.g. /volume2/docker/garage/docker-compose.yml). "
                         "Driven from the spec — no implicit volume mapping.")
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

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
