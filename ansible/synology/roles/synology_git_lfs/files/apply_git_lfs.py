#!/usr/bin/env python3
"""Deploy the giftless Git LFS server on DSM idempotently.

Subcommands:
  render   Write giftless.yaml (GitHub auth restricted to the spec's orgs,
           local-storage streaming transfer, no JWT pre-auth) and the
           krg_public_url.py WSGI middleware that pins giftless's
           self-referencing URLs to the public origin. sha256 compare for
           idempotency; atomic writes. No secrets involved.
  deploy   Write docker-compose.yml + `docker compose up -d` when the
           container drifts (compose / image / not running). --config-changed
           (render rewrote a file) restarts an otherwise-current container,
           since giftless reads its config once at startup.

Invoked by the synology_git_lfs ansible role via the `script` module. Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.
Self-contained on purpose: `script:` ships exactly this one file to the NAS.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse


# Same docker PATH fix as apply_garage.py: DSM's sudo secure_path omits the
# Container Manager install locations.
_DSM_DOCKER_PATHS = (
    "/usr/local/bin",
    "/var/packages/ContainerManager/target/usr/bin",
    "/var/packages/Docker/target/usr/bin",
)
os.environ["PATH"] = ":".join(_DSM_DOCKER_PATHS) + ":" + os.environ.get("PATH", "")

# Where the image expects things. STORAGE_MOUNT must match the image's
# GIFTLESS_TRANSFER_ADAPTERS_basic_options_storage_options_path env (giftless
# applies env AFTER the config file, so the image's value wins regardless).
STORAGE_MOUNT = "/lfs-storage"
CONFIG_MOUNT = "/etc/giftless/giftless.yaml"
MIDDLEWARE_DIR = "/opt/krg"
MIDDLEWARE_MODULE = "krg_public_url"

# giftless builds absolute hrefs (verify / object URLs) with Flask's
# url_for(_external=True), i.e. from the request's scheme + Host. Behind the DSM
# proxy those are http + whatever Host nginx forwards, so pin both to the public
# origin here instead of depending on DSM's X-Forwarded-* behaviour.
MIDDLEWARE_SOURCE = '''\
# RENDERED BY synology_git_lfs ansible role — DO NOT HAND-EDIT.
"""Pin giftless's self-referencing URLs to the public origin."""


class FixedPublicURL:
    def __init__(self, app, scheme, host):
        self.app = app
        self.scheme = scheme
        self.host = host

    def __call__(self, environ, start_response):
        environ["wsgi.url_scheme"] = self.scheme
        environ["HTTP_HOST"] = self.host
        return self.app(environ, start_response)
'''

COMPOSE_TEMPLATE = """\
# RENDERED BY synology_git_lfs ansible role — DO NOT HAND-EDIT.
# Source of truth: spec/e4e-nas/git-lfs.yml.
services:
  %(container_name)s:
    image: %(image)s:%(image_tag)s
    container_name: %(container_name)s
    restart: %(restart_policy)s
    network_mode: host
    # root, so it can write through the git-lfs-store share's Synology ACL
    # (administrators-only), but with every capability dropped except the
    # file-permission overrides that needs.
    user: "0:0"
    cap_drop: [ALL]
    cap_add: [DAC_OVERRIDE, DAC_READ_SEARCH, FOWNER]
    security_opt: ["no-new-privileges:true"]
    environment:
      GIFTLESS_CONFIG_FILE: %(config_mount)s
    command: ["--http-socket", "%(bind_host)s:%(port)s", "--master", "--enable-threads", "--processes", "%(processes)s", "--threads", "%(threads)s", "--manage-script-name", "--callable", "app", "--need-app", "--pythonpath", "%(middleware_dir)s"]
    volumes:
      - %(storage_dir)s:%(storage_mount)s
      - %(config_path)s:%(config_mount)s:ro
      - %(middleware_path)s:%(middleware_dir)s/%(middleware_module)s.py:ro
"""


# ---------------------------------------------------------------------------
# helpers (copied from apply_garage.py — each apply_*.py ships standalone)
# ---------------------------------------------------------------------------
def _run(*cmd, **kw):
    try:
        return subprocess.run(list(cmd), capture_output=True, text=True, **kw)
    except FileNotFoundError as e:
        return subprocess.CompletedProcess(
            args=list(cmd),
            returncode=127,
            stdout="",
            stderr="binary not found on PATH: %s (%s)" % (cmd[0] if cmd else "<empty>", e),
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
# render
# ---------------------------------------------------------------------------
def _parse_public_url(url):
    """Return (scheme, host) or None. https only: clients send a GitHub token
    in every request, so a plain-http origin is refused outright."""
    u = urllib.parse.urlsplit(url)
    if u.scheme != "https" or not u.netloc or u.path not in ("", "/") or u.query:
        return None
    return u.scheme, u.netloc


def render_config(orgs, scheme, host):
    """giftless.yaml content. Rendered as JSON (a YAML subset giftless's
    yaml.safe_load reads fine) so it is deterministic with no YAML lib on DSM."""
    cfg = {
        # /<org>/<repo>.git/info/lfs/ endpoints only.
        "LEGACY_ENDPOINTS": False,
        "AUTH_PROVIDERS": [
            {
                "factory": "giftless.auth.github:factory",
                "options": {"restrict_to": {o: None for o in orgs}},
            }
        ],
        # The default pre-auth provider signs object URLs with a JWT key that
        # defaults to the literal "change-me" (forgeable). Disabled, so every
        # object request is authorized via GitHub like the batch call.
        "PRE_AUTHORIZED_ACTION_PROVIDER": None,
        "TRANSFER_ADAPTERS": {
            "basic": {
                "factory": "giftless.transfer.basic_streaming:factory",
                "options": {
                    "storage_class": "giftless.storage.local_storage:LocalStorage",
                    "storage_options": {"path": STORAGE_MOUNT},
                    "action_lifetime": 900,
                },
            }
        },
        "MIDDLEWARE": [
            {
                "class": MIDDLEWARE_MODULE + ":FixedPublicURL",
                "kwargs": {"scheme": scheme, "host": host},
            }
        ],
    }
    return (
        "# RENDERED BY synology_git_lfs ansible role — DO NOT HAND-EDIT.\n"
        "# Source of truth: spec/e4e-nas/git-lfs.yml.\n"
        + json.dumps(cfg, indent=2, sort_keys=True)
        + "\n"
    )


def do_render(a):
    try:
        orgs = json.loads(a.github_orgs_json)
    except ValueError as e:
        return _fail({"reason": "--github-orgs-json is not valid JSON", "error": str(e)})
    if not isinstance(orgs, list) or not orgs or not all(isinstance(o, str) and o for o in orgs):
        # restrict_to is the only thing keeping arbitrary GitHub users' repos out.
        return _fail({"reason": "github.orgs must be a non-empty list of org names", "orgs": orgs})
    origin = _parse_public_url(a.public_url)
    if origin is None:
        return _fail(
            {
                "reason": "public_url must be a bare https://host[:port] origin",
                "public_url": a.public_url,
            }
        )

    desired = {
        a.config_path: render_config(orgs, origin[0], origin[1]),
        a.middleware_path: MIDDLEWARE_SOURCE,
    }
    changed = sorted(p for p, body in desired.items() if _read(p) != body)
    if not changed:
        return _emit("no-change", {}, a.check)
    payload = {"files": changed, "sha256": {p: _sha256(desired[p]) for p in changed}}
    if a.check:
        return _emit("would-change", payload, True)
    for p in changed:
        _atomic_write(p, desired[p], 0o644)
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------
def _container_running(name):
    r = _run("docker", "inspect", "--format", "{{.State.Running}}", name)
    return r.returncode == 0 and r.stdout.strip() == "true"


def _container_image(name):
    r = _run("docker", "inspect", "--format", "{{.Config.Image}}", name)
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def render_compose(a):
    return COMPOSE_TEMPLATE % {
        "container_name": a.container_name,
        "image": a.image,
        "image_tag": a.image_tag,
        "restart_policy": a.restart_policy,
        "bind_host": a.bind_host,
        "port": a.port,
        "processes": a.processes,
        "threads": a.threads,
        "storage_dir": a.storage_dir,
        "storage_mount": STORAGE_MOUNT,
        "config_path": a.config_path,
        "config_mount": CONFIG_MOUNT,
        "middleware_path": a.middleware_path,
        "middleware_dir": MIDDLEWARE_DIR,
        "middleware_module": MIDDLEWARE_MODULE,
    }


def do_deploy(a):
    missing = [p for p in (a.config_path, a.middleware_path) if not os.path.exists(p)]
    if missing:
        if not a.check:
            return _fail(
                {"reason": "rendered files missing — run render first", "missing": missing}
            )
        return _emit(
            "would-change",
            {"missing": missing, "reason": "render must run before deploy on apply"},
            True,
        )

    desired_compose = render_compose(a)
    desired_image = "%s:%s" % (a.image, a.image_tag)
    compose_drift = _read(a.compose_path) != desired_compose
    current_image = _container_image(a.container_name)
    image_drift = current_image != desired_image
    not_running = not _container_running(a.container_name)
    storage_missing = not os.path.isdir(a.storage_dir)

    recreate = compose_drift or image_drift or not_running
    payload = {
        "compose_path": a.compose_path,
        "compose_drift": compose_drift,
        "image_drift": image_drift,
        "image_current": current_image,
        "image_desired": desired_image,
        "not_running": not_running,
        "config_changed": a.config_changed,
        "storage_missing": storage_missing,
    }
    if not (recreate or a.config_changed or storage_missing):
        return _emit("no-change", {}, a.check)
    if a.check:
        return _emit("would-change", payload, True)

    # Create the storage dir ourselves rather than letting docker invent the
    # bind-mount source, so it is made inside the share and picks up the
    # share's inherited ACL.
    if storage_missing:
        os.makedirs(a.storage_dir, exist_ok=True)
    if compose_drift:
        _atomic_write(a.compose_path, desired_compose, 0o644)

    if recreate:
        r = _run("docker", "compose", "-f", a.compose_path, "up", "-d")
        op = "up"
    elif a.config_changed:
        r = _run("docker", "compose", "-f", a.compose_path, "restart")
        op = "restart"
    else:
        return _emit("changed", payload, False)
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

    rn = sub.add_parser("render")
    rn.add_argument("--config-path", required=True)
    rn.add_argument("--middleware-path", required=True)
    rn.add_argument("--public-url", required=True)
    rn.add_argument(
        "--github-orgs-json", required=True, help='JSON array of GitHub orgs, e.g. ["UCSD-E4E"]'
    )
    rn.add_argument("--check", action="store_true")
    rn.set_defaults(fn=do_render)

    dp = sub.add_parser("deploy")
    dp.add_argument("--compose-path", required=True)
    dp.add_argument("--container-name", required=True)
    dp.add_argument("--image", required=True)
    dp.add_argument("--image-tag", required=True)
    dp.add_argument("--restart-policy", required=True)
    dp.add_argument("--config-path", required=True)
    dp.add_argument("--middleware-path", required=True)
    dp.add_argument("--storage-dir", required=True)
    dp.add_argument("--bind-host", required=True)
    dp.add_argument("--port", required=True, type=int)
    dp.add_argument("--processes", required=True, type=int)
    dp.add_argument("--threads", required=True, type=int)
    # render rewrote a file this run → restart to reload it.
    dp.add_argument("--config-changed", action="store_true")
    dp.add_argument("--check", action="store_true")
    dp.set_defaults(fn=do_deploy)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
