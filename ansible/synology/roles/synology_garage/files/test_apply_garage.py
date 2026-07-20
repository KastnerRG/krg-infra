"""Unit tests for apply_garage.py — pytest, no DSM needed.

The script's three subcommands shell out to (a) the filesystem and (b)
`docker` / `garage` binaries. Tests monkeypatch `_run`, `_read`, and
`_atomic_write` so nothing escapes the test process.
"""

import io
import json
import os
import subprocess  # noqa: F401  (referenced in monkeypatch targets)
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import apply_garage as m  # noqa: E402


# --- fixtures -----------------------------------------------------------------
def _render_args(**overrides):
    """Default arg-namespace for render-config; override per test."""
    base = {
        "config_path": "/volume1/docker/garage/garage.toml",
        "db_engine": "lmdb",
        "replication_factor": 1,
        "compression_level": 2,
        "rpc_bind_addr": "[::]:3901",
        "rpc_public_addr": "127.0.0.1:3901",
        "s3_api_bind_addr": "[::]:3900",
        "s3_region": "garage",
        "s3_root_domain": ".s3.e4e.ucsd.edu",
        "s3_web_bind_addr": "[::]:3902",
        "s3_web_root_domain": ".web.e4e.ucsd.edu",
        "s3_web_index": "index.html",
        "admin_api_bind_addr": "[::]:3903",
        "meta_dir": "/volume2/s3-data/meta",
        "data_dir": "/volume2/s3-data/data",
        "check": False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _set_secret_env(monkeypatch, rpc="a" * 64, admin="b" * 64, metrics="c" * 64):
    """Default-set the three secret env vars; tests can override or unset."""
    monkeypatch.setenv("GARAGE_RPC_SECRET", rpc)
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", admin)
    monkeypatch.setenv("GARAGE_METRICS_TOKEN", metrics)


def _deploy_args(**overrides):
    base = {
        "compose_path": "/volume1/docker/garage/docker-compose.yml",
        "container_name": "garage",
        "image": "dxflrs/garage",
        "image_tag": "v1.1.0",
        "network_mode": "host",
        "restart_policy": "unless-stopped",
        "meta_dir": "/volume2/s3-data/meta",
        "data_dir": "/volume2/s3-data/data",
        "config_path": "/volume1/docker/garage/garage.toml",
        "rust_log": "garage=info",
        "check": False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _layout_args(**overrides):
    base = {
        "container_name": "garage",
        "zone": "dc1",
        "capacity": "5T",
        "check": False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _render_ui_args(**overrides):
    base = {
        "config_path": "/volume1/docker/garage-ui/config.yaml",
        "bind_host": "127.0.0.1",
        "port": "8080",
        "public_hostname": "s3-admin.e4e.ucsd.edu",
        "public_url": "https://s3-admin.e4e.ucsd.edu",
        "garage_s3_port": "3900",
        "garage_admin_port": "3903",
        "garage_region": "garage",
        "oidc_provider_name": "Authentik",
        "oidc_client_id": "garage-ui",
        "oidc_issuer_url": "https://auth.example.com/application/o/garage-ui/",
        "oidc_role_attribute_path": "groups",
        "oidc_scopes_json": '["openid","email","profile","groups"]',
        "oidc_admin_roles_json": '["Garage Admins"]',
        "check": False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _deploy_ui_args(**overrides):
    base = {
        "compose_path": "/volume1/docker/garage-ui/docker-compose.yml",
        "container_name": "garage-ui",
        "image": "noooste/garage-ui",
        "image_tag": "v0.6.1",
        "config_path": "/volume1/docker/garage-ui/config.yaml",
        "config_changed": False,
        "check": False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _set_ui_secret_env(monkeypatch, oidc="y" * 32, admin=None):
    """Set GARAGE_UI_OIDC_CLIENT_SECRET (+ GARAGE_ADMIN_TOKEN if given)."""
    monkeypatch.setenv("GARAGE_UI_OIDC_CLIENT_SECRET", oidc)
    if admin is not None:
        monkeypatch.setenv("GARAGE_ADMIN_TOKEN", admin)


class _RunResult:
    def __init__(self, rc, stdout="", stderr=""):
        self.returncode = rc
        self.stdout = stdout
        self.stderr = stderr


# --- render-config ------------------------------------------------------------
def test_render_config_writes_when_missing(monkeypatch, capsys):
    _set_secret_env(monkeypatch)
    monkeypatch.setattr(m, "_read", lambda p: None)
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_render_config(_render_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["had_existing"] is False
    assert payload["config_path"] == "/volume1/docker/garage/garage.toml"
    assert "rpc_secret" not in out and "admin_token" not in out and "metrics_token" not in out
    assert len(writes) == 1
    path, content, mode = writes[0]
    assert path == "/volume1/docker/garage/garage.toml" and mode == 0o400
    # The rendered TOML must include the secret values + structural fields:
    assert 'rpc_secret = "' + "a" * 64 + '"' in content
    assert 'admin_token = "' + "b" * 64 + '"' in content
    assert 'metrics_token = "' + "c" * 64 + '"' in content
    assert 'db_engine = "lmdb"' in content
    assert "replication_factor = 1" in content
    assert 'root_domain = ".s3.e4e.ucsd.edu"' in content


def test_render_config_fails_clean_when_secret_env_unset(monkeypatch, capsys):
    """Missing secret env var → structured FAIL with clear reason (NOT a
    Python KeyError traceback). Confirms the env-var contract is enforced."""
    monkeypatch.delenv("GARAGE_RPC_SECRET", raising=False)
    monkeypatch.delenv("GARAGE_ADMIN_TOKEN", raising=False)
    monkeypatch.delenv("GARAGE_METRICS_TOKEN", raising=False)

    rc = m.do_render_config(_render_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert set(payload["vars"]) == {
        "GARAGE_RPC_SECRET",
        "GARAGE_ADMIN_TOKEN",
        "GARAGE_METRICS_TOKEN",
    }


def test_render_config_no_change_on_identical(monkeypatch, capsys):
    # Pre-render the desired output, hand it back as the existing file content.
    _set_secret_env(monkeypatch)
    a = _render_args()
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
    existing = m.GARAGE_TOML_TEMPLATE % fields
    monkeypatch.setattr(m, "_read", lambda p: existing)
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_render_config(a)
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert writes == []


def test_render_config_check_mode_doesnt_write(monkeypatch, capsys):
    _set_secret_env(monkeypatch)
    monkeypatch.setattr(m, "_read", lambda p: None)
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_render_config(_render_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    assert writes == []


@pytest.mark.parametrize(
    "bad_secret",
    [
        'abc"def',  # double-quote breaks the TOML basic-string literal
        "abc\ndef",  # raw newline can't appear in a basic string
        "abc\rdef",  # raw CR likewise
        'multi"line\nbad',  # combo
    ],
)
def test_render_config_rejects_injection_chars_in_secret(monkeypatch, capsys, bad_secret):
    """Defense against TOML literal-break injection — `openssl rand -hex 32`
    can't produce these but validate at the bottleneck. Quote OR newline
    closes a basic string early."""
    _set_secret_env(monkeypatch, rpc=bad_secret)
    monkeypatch.setattr(m, "_read", lambda p: None)
    rc = m.do_render_config(_render_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["field"] == "rpc_secret"


def test_render_config_secret_redacted_in_changed_payload(monkeypatch, capsys):
    _set_secret_env(monkeypatch, rpc="SUPERSECRET" * 4)
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m, "_atomic_write", lambda *a, **kw: None)
    rc = m.do_render_config(_render_args())
    out = capsys.readouterr().out
    assert rc == 0
    assert "SUPERSECRET" not in out


# --- deploy -------------------------------------------------------------------
def test_deploy_no_change(monkeypatch, capsys):
    # Build the desired compose, hand it back as the existing file content.
    a = _deploy_args()
    desired = m.COMPOSE_TEMPLATE % {
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
    monkeypatch.setattr(m, "_read", lambda p: desired)
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(m, "_container_image", lambda n: "dxflrs/garage:v1.1.0")

    rc = m.do_deploy(a)
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_deploy_image_drift_triggers_compose_up(monkeypatch, capsys):
    a = _deploy_args(image_tag="v1.2.0")
    desired_compose = m.COMPOSE_TEMPLATE % {
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
    monkeypatch.setattr(m, "_read", lambda p: desired_compose)  # compose matches
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(
        m, "_container_image", lambda n: "dxflrs/garage:v1.1.0"
    )  # but image drifted

    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))
    monkeypatch.setattr(m.os, "makedirs", lambda p, exist_ok=False: None)
    runs = []

    def fake_run(*cmd, **kw):
        runs.append(cmd)
        return _RunResult(0, stdout="garage Recreated\n")

    monkeypatch.setattr(m, "_run", fake_run)

    rc = m.do_deploy(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["image_drift"] is True
    assert payload["compose_drift"] is False
    assert payload["not_running"] is False
    # compose-up MUST be called even when only the image drifted (the compose
    # file is unchanged on disk but `docker compose up` re-pulls + recreates).
    assert any("compose" in c and "up" in c for c in runs)


def test_deploy_missing_garage_toml_fails_on_apply(monkeypatch, capsys):
    """Apply mode (no --check): missing config_path is a hard ordering bug."""
    a = _deploy_args()
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)  # garage.toml missing

    rc = m.do_deploy(a)
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "render-config" in payload["reason"]


def test_deploy_missing_garage_toml_reports_planned_change_in_check(monkeypatch, capsys):
    """--check on a fresh box (no garage.toml yet) must NOT fail — it should
    report WOULD-CHANGE so `--check --diff` is a usable dry-run."""
    a = _deploy_args(check=True)
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)
    runs = []
    monkeypatch.setattr(m, "_run", lambda *cmd, **kw: runs.append(cmd) or _RunResult(0))

    rc = m.do_deploy(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["config_missing"] is True
    # MUST NOT invoke docker in check mode
    assert runs == []


# --- layout: readiness wait ------------------------------------------------------
# Regression cover for the 2026-07-20 fleet-deploy failure: `deploy` recreates the
# container and returns as soon as it EXISTS, so `layout` raced Garage's RPC socket
# and hard-failed with "Connection refused (os error 111)" one second later.
def test_layout_waits_for_garage_rpc_then_succeeds(monkeypatch, capsys):
    """A daemon that is slow to open :3901 is waited for, not failed on."""
    a = _layout_args()
    refused = _RunResult(1, stderr="IO error: Connection refused (os error 111)\n")
    outputs = iter(
        [
            refused,  # status: container up but not listening yet
            refused,  # status: still starting
            _RunResult(0, stdout="==== HEALTHY NODES ====\nabc1234567890def NO ROLE 10.0.0.1\n"),
            _RunResult(0, stdout="Current cluster layout version: 1\n"),
        ]
    )
    monkeypatch.setattr(m, "_run", lambda *cmd, **kw: next(outputs))
    slept = []
    monkeypatch.setattr(m.time, "sleep", lambda s: slept.append(s))

    rc = m.do_layout(a)

    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert slept, "expected the readiness poll to back off between attempts"


def test_layout_still_fails_when_garage_never_comes_up(monkeypatch, capsys):
    """The wait is bounded — a genuinely dead daemon must still FAIL, not hang."""
    a = _layout_args()
    monkeypatch.setattr(
        m,
        "_run",
        lambda *cmd, **kw: _RunResult(1, stderr="IO error: Connection refused (os error 111)\n"),
    )
    # Virtual clock so the bounded wait elapses without real sleeping.
    ticks = iter([0.0] + [float(i) * 10.0 for i in range(1, 200)])
    monkeypatch.setattr(m.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(m.time, "sleep", lambda s: None)

    rc = m.do_layout(a)

    out = capsys.readouterr().out
    assert rc != 0 and "FAIL" in out and "container not ready" in out


def test_layout_check_mode_does_not_wait(monkeypatch, capsys):
    """--check probes once: a dry run must not block for the full timeout."""
    a = _layout_args(check=True)
    calls = []

    def fake_run(*cmd, **kw):
        calls.append(cmd)
        return _RunResult(1, stderr="IO error: Connection refused (os error 111)\n")

    monkeypatch.setattr(m, "_run", fake_run)

    def _no_sleep(_s):
        raise AssertionError("--check must not sleep waiting for Garage")

    monkeypatch.setattr(m.time, "sleep", _no_sleep)

    rc = m.do_layout(a)

    assert rc == 0 and "WOULD-CHANGE" in capsys.readouterr().out
    assert len(calls) == 1, "check mode should probe exactly once"


# --- layout -------------------------------------------------------------------
def test_layout_no_change_when_version_already_assigned(monkeypatch, capsys):
    a = _layout_args()
    outputs = iter(
        [
            _RunResult(0, stdout="==== HEALTHY NODES ====\nabc1234567890def NO ROLE 10.0.0.1\n"),
            _RunResult(
                0,
                stdout="Current cluster layout version: 1\nID  Tags Zone Capacity\nabc1 ... dc1 5T\n",
            ),
        ]
    )

    def fake_run(*cmd, **kw):
        return next(outputs)

    monkeypatch.setattr(m, "_run", fake_run)

    rc = m.do_layout(a)
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_layout_assigns_when_version_zero(monkeypatch, capsys):
    a = _layout_args()
    status_out = (
        "==== HEALTHY NODES ====\n"
        "abc1234567890def  NO ROLE ASSIGNED  10.0.0.1:3901  garage  HEALTHY\n"
    )
    outputs = iter(
        [
            _RunResult(0, stdout=status_out),  # garage status (probe)
            _RunResult(0, stdout="Current cluster layout version: 0\n"),  # garage layout show
            _RunResult(0, stdout=status_out),  # garage status (for node id)
            _RunResult(0, stdout="Role changes staged\n"),  # garage layout assign
            _RunResult(0, stdout="Layout version 1 applied\n"),  # garage layout apply
        ]
    )
    calls = []

    def fake_run(*cmd, **kw):
        calls.append(cmd)
        return next(outputs)

    monkeypatch.setattr(m, "_run", fake_run)

    rc = m.do_layout(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["node_id"] == "abc1234567890def"
    assert payload["zone"] == "dc1" and payload["capacity"] == "5T"
    assert payload["version"] == 1
    # Calls 4+5 should be the assign + apply.
    assigned = calls[3]
    applied = calls[4]
    assert "assign" in assigned and "-z" in assigned and "dc1" in assigned
    assert "-c" in assigned and "5T" in assigned
    assert "abc1234567890def" in assigned
    assert "apply" in applied and "--version" in applied and "1" in applied


def test_layout_truncates_full_64char_id(monkeypatch, capsys):
    # Future-proofing: if a Garage release prints the full 64-hex node id in
    # `garage status`, we still feed the 16-char short form to `layout assign`.
    a = _layout_args()
    full_id = "f" * 64
    status_out = (
        f"==== HEALTHY NODES ====\n{full_id}  NO ROLE ASSIGNED  10.0.0.1:3901  garage  HEALTHY\n"
    )
    outputs = iter(
        [
            _RunResult(0, stdout=status_out),  # probe
            _RunResult(0, stdout="Current cluster layout version: 0\n"),  # show
            _RunResult(0, stdout=status_out),  # node-id lookup
            _RunResult(0, stdout="staged\n"),  # assign
            _RunResult(0, stdout="applied\n"),  # apply
        ]
    )
    calls = []

    def fake_run(*cmd, **kw):
        calls.append(cmd)
        return next(outputs)

    monkeypatch.setattr(m, "_run", fake_run)

    rc = m.do_layout(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["node_id"] == "f" * 16  # truncated to 16
    # And the assign call passed the truncated form, not the full id.
    assign_cmd = calls[3]
    assert "f" * 16 in assign_cmd
    assert "f" * 64 not in assign_cmd


def test_layout_fails_clean_when_garage_not_responsive(monkeypatch, capsys):
    a = _layout_args()
    monkeypatch.setattr(m, "_run", lambda *cmd, **kw: _RunResult(1, stderr="rpc dial err"))
    # A real apply now POLLS for readiness before giving up, so drive a virtual
    # clock — otherwise this test really would sit out GARAGE_READY_TIMEOUT.
    ticks = iter([0.0] + [float(i) * 10.0 for i in range(1, 200)])
    monkeypatch.setattr(m.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(m.time, "sleep", lambda s: None)

    rc = m.do_layout(a)
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "container not ready" in payload["reason"]


def test_layout_check_reports_planned_when_container_down(monkeypatch, capsys):
    """In --check the container may not be up yet (preview on a fresh box).
    Must report WOULD-CHANGE rather than FAIL so dry-run is usable."""
    a = _layout_args(check=True)
    monkeypatch.setattr(m, "_run", lambda *cmd, **kw: _RunResult(1, stderr="container not found"))

    rc = m.do_layout(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["zone"] == "dc1" and payload["capacity"] == "5T"


# --- _run binary-missing handling --------------------------------------------
def test_run_returns_structured_failure_when_binary_missing(monkeypatch):
    """If `docker` (or any subprocess target) isn't on PATH, `_run` must
    return a CompletedProcess with non-zero returncode + stderr explaining
    the miss — not raise FileNotFoundError. Without this guard, callers
    that don't catch the exception (do_deploy / do_layout) would surface
    as a Python traceback, bypassing the OK/.../FAIL contract."""

    def boom(*args, **kwargs):
        raise FileNotFoundError(2, "No such file or directory", "docker")

    monkeypatch.setattr(m.subprocess, "run", boom)
    r = m._run("docker", "ps")
    assert r.returncode == 127
    assert "binary not found on PATH" in r.stderr
    assert "docker" in r.stderr


# --- argparse plumbing --------------------------------------------------------
def test_main_dispatches_to_subcommand(monkeypatch, capsys):
    monkeypatch.setattr(m, "do_render_config", lambda a: print("OK no-change") or 0)
    rc = m.main(
        [
            "render-config",
            "--config-path",
            "/tmp/x.toml",
            "--db-engine",
            "lmdb",
            "--replication-factor",
            "1",
            "--compression-level",
            "2",
            "--rpc-bind-addr",
            "[::]:3901",
            "--rpc-public-addr",
            "127.0.0.1:3901",
            "--s3-api-bind-addr",
            "[::]:3900",
            "--s3-region",
            "garage",
            "--s3-root-domain",
            ".x",
            "--s3-web-bind-addr",
            "[::]:3902",
            "--s3-web-root-domain",
            ".y",
            "--s3-web-index",
            "index.html",
            "--admin-api-bind-addr",
            "[::]:3903",
            # Secrets are read from env vars now, not argv — see do_render_config.
            "--meta-dir",
            "/m",
            "--data-dir",
            "/d",
        ]
    )
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


# --- render-ui-config ---------------------------------------------------------
def test_render_ui_config_writes_when_missing(monkeypatch, capsys):
    """OIDC client_secret + admin_token come from env vars (NEVER argv).
    JWT key is generated + persisted alongside config on first run."""
    _set_ui_secret_env(monkeypatch, oidc="y" * 32, admin="x" * 64)
    monkeypatch.setattr(m, "_read", lambda p: "PEM-CONTENT")
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)
    monkeypatch.setattr(m, "_ensure_jwt_key", lambda p: "PEM-CONTENT")
    writes = []
    monkeypatch.setattr(
        m, "_atomic_write", lambda p, c, mode, uid=0, gid=0: writes.append((p, c, mode, uid, gid))
    )

    rc = m.do_render_ui_config(_render_ui_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["key_generated"] is True
    assert payload["config_path"] == "/volume1/docker/garage-ui/config.yaml"
    # No secret leaks in payload (only hash):
    assert "y" * 32 not in out and "x" * 64 not in out
    _, content, mode, uid, gid = writes[0]
    assert mode == 0o400
    # config.yaml is owned by the non-root garage-ui container UID so the
    # container reads its own secret config without running as root.
    assert (uid, gid) == (m._GARAGE_UI_UID, m._GARAGE_UI_GID) == (1000, 1000)
    assert 'client_secret: "' + "y" * 32 + '"' in content
    assert 'admin_token: "' + "x" * 64 + '"' in content
    assert 'root_url: "https://s3-admin.e4e.ucsd.edu"' in content
    assert '- "Garage Admins"' in content
    for s in ("openid", "email", "profile", "groups"):
        assert '- "%s"' % s in content


def test_render_ui_config_fails_clean_when_oidc_secret_unset(monkeypatch, capsys):
    """Missing GARAGE_UI_OIDC_CLIENT_SECRET → structured FAIL."""
    monkeypatch.delenv("GARAGE_UI_OIDC_CLIENT_SECRET", raising=False)
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "x" * 64)
    rc = m.do_render_ui_config(_render_ui_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == ["GARAGE_UI_OIDC_CLIENT_SECRET"]


def test_render_ui_config_fails_clean_when_admin_token_unset(monkeypatch, capsys):
    """Missing GARAGE_ADMIN_TOKEN → structured FAIL (UI reuses the cluster
    admin_token to call Garage's admin API)."""
    monkeypatch.setenv("GARAGE_UI_OIDC_CLIENT_SECRET", "y" * 32)
    monkeypatch.delenv("GARAGE_ADMIN_TOKEN", raising=False)
    rc = m.do_render_ui_config(_render_ui_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == ["GARAGE_ADMIN_TOKEN"]


def test_render_ui_config_check_mode_doesnt_write_or_genkey(monkeypatch, capsys):
    _set_ui_secret_env(monkeypatch, oidc="y" * 32, admin="x" * 64)
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)
    genkey_called = []
    monkeypatch.setattr(m, "_ensure_jwt_key", lambda p: genkey_called.append(p) or "PEM")
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_render_ui_config(_render_ui_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    assert writes == [] and genkey_called == []  # never side-effect in check mode


@pytest.mark.parametrize(
    "field,bad",
    [
        ("oidc_client_secret", '"'),
        ("garage_admin_token", "\n"),
    ],
)
def test_render_ui_config_rejects_injection_chars(monkeypatch, capsys, field, bad):
    """Reject `"`, `\\n`, `\\r` in any YAML string field — defense in depth."""
    if field == "oidc_client_secret":
        _set_ui_secret_env(monkeypatch, oidc="abc" + bad + "def", admin="x" * 64)
    else:
        _set_ui_secret_env(monkeypatch, oidc="y" * 32, admin="abc" + bad + "def")
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_read", lambda p: "PEM")
    rc = m.do_render_ui_config(_render_ui_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["field"] == field


def test_render_ui_config_rejects_empty_admin_roles(monkeypatch, capsys):
    _set_ui_secret_env(monkeypatch, oidc="y" * 32, admin="x" * 64)
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_read", lambda p: "PEM")
    rc = m.do_render_ui_config(_render_ui_args(oidc_admin_roles_json="[]"))
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "admin_roles" in payload["reason"]


def test_yaml_list_lines_quotes_and_indents():
    out = m._yaml_list_lines(["openid", "email", "profile"], 6)
    assert out == '      - "openid"\n      - "email"\n      - "profile"'


def test_yaml_list_lines_rejects_doublequote():
    with pytest.raises(ValueError):
        m._yaml_list_lines(['has"quote'], 6)


def test_yaml_list_lines_rejects_newline():
    with pytest.raises(ValueError):
        m._yaml_list_lines(["has\nnewline"], 6)


# --- deploy-ui ----------------------------------------------------------------
def test_deploy_ui_no_change(monkeypatch, capsys):
    a = _deploy_ui_args()
    desired_compose = m.GARAGE_UI_COMPOSE_TEMPLATE % {
        "container_name": a.container_name,
        "image": a.image,
        "image_tag": a.image_tag,
        "config_path": a.config_path,
    }
    monkeypatch.setattr(m, "_read", lambda p: desired_compose)
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(m, "_container_image", lambda n: "noooste/garage-ui:v0.6.1")

    rc = m.do_deploy_ui(a)
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_deploy_ui_missing_config_fails_on_apply(monkeypatch, capsys):
    a = _deploy_ui_args()
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)
    rc = m.do_deploy_ui(a)
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "render-ui-config" in payload["reason"]


def test_deploy_ui_missing_config_check_mode_planned(monkeypatch, capsys):
    """--check on a fresh box (no config.yaml yet) reports WOULD-CHANGE."""
    a = _deploy_ui_args(check=True)
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)
    runs = []
    monkeypatch.setattr(m, "_run", lambda *cmd, **kw: runs.append(cmd) or _RunResult(0))
    rc = m.do_deploy_ui(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    assert runs == []


def test_deploy_ui_image_drift_triggers_compose_up(monkeypatch, capsys):
    a = _deploy_ui_args(image_tag="0.7.0")
    desired_compose = m.GARAGE_UI_COMPOSE_TEMPLATE % {
        "container_name": a.container_name,
        "image": a.image,
        "image_tag": a.image_tag,
        "config_path": a.config_path,
    }
    monkeypatch.setattr(m, "_read", lambda p: desired_compose)
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(m, "_container_image", lambda n: "noooste/garage-ui:v0.6.1")
    monkeypatch.setattr(m.os, "makedirs", lambda p, exist_ok=False: None)
    monkeypatch.setattr(m, "_atomic_write", lambda *a, **kw: None)
    runs = []

    def fake_run(*cmd, **kw):
        runs.append(cmd)
        return _RunResult(0, stdout="garage-ui Recreated\n")

    monkeypatch.setattr(m, "_run", fake_run)

    rc = m.do_deploy_ui(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["image_drift"] is True
    assert any("compose" in c and "up" in c for c in runs)


def test_deploy_ui_config_changed_restarts_container(monkeypatch, capsys):
    """config.yaml content changed but compose/image/running are all stable:
    deploy-ui must `docker compose restart` (NOT `up -d`, which won't restart an
    up-to-date container) so garage-ui re-reads the new config at startup."""
    a = _deploy_ui_args(config_changed=True)
    desired_compose = m.GARAGE_UI_COMPOSE_TEMPLATE % {
        "container_name": a.container_name,
        "image": a.image,
        "image_tag": a.image_tag,
        "config_path": a.config_path,
    }
    monkeypatch.setattr(m, "_read", lambda p: desired_compose)
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(m, "_container_image", lambda n: "noooste/garage-ui:v0.6.1")
    monkeypatch.setattr(m.os, "makedirs", lambda p, exist_ok=False: None)
    monkeypatch.setattr(m, "_atomic_write", lambda *a, **kw: None)
    runs = []
    monkeypatch.setattr(
        m,
        "_run",
        lambda *cmd, **kw: runs.append(cmd) or _RunResult(0, stdout="garage-ui Restarted\n"),
    )

    rc = m.do_deploy_ui(a)
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["config_changed"] is True
    assert payload["compose_drift"] is False and payload["image_drift"] is False
    assert any("restart" in c for c in runs)
    assert not any("up" in c for c in runs)


# --- _admin_request -------------------------------------------------------------
class _FakeHTTPResponse:
    def __init__(self, status, body_bytes):
        self.status = status
        self._body = body_bytes

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_admin_request_success(monkeypatch):
    def fake_urlopen(req, timeout=10):
        assert req.get_header("Authorization") == "Bearer tok"
        assert req.full_url == "http://127.0.0.1:3903/v2/ListBuckets"
        return _FakeHTTPResponse(200, b'{"ok":true}')

    monkeypatch.setattr(m.urllib.request, "urlopen", fake_urlopen)
    status, body = m._admin_request(3903, "tok", "GET", "/v2/ListBuckets")
    assert status == 200 and body == {"ok": True}


def test_admin_request_encodes_query_and_body(monkeypatch):
    seen = {}

    def fake_urlopen(req, timeout=10):
        seen["url"] = req.full_url
        seen["data"] = req.data
        seen["content_type"] = req.get_header("Content-type")
        return _FakeHTTPResponse(201, b"{}")

    monkeypatch.setattr(m.urllib.request, "urlopen", fake_urlopen)
    m._admin_request(
        3903, "tok", "POST", "/v2/CreateBucket", query={"id": "abc"}, body={"globalAlias": "x"}
    )
    assert seen["url"] == "http://127.0.0.1:3903/v2/CreateBucket?id=abc"
    assert json.loads(seen["data"]) == {"globalAlias": "x"}
    assert seen["content_type"] == "application/json"


def test_admin_request_http_error_returns_status_and_body(monkeypatch):
    def fake_urlopen(req, timeout=10):
        raise m.urllib.error.HTTPError(
            req.full_url, 403, "Forbidden", None, io.BytesIO(b'{"error":"bad token"}')
        )

    monkeypatch.setattr(m.urllib.request, "urlopen", fake_urlopen)
    status, body = m._admin_request(3903, "tok", "GET", "/v2/ListBuckets")
    assert status == 403 and body == {"error": "bad token"}


# --- sync-buckets ---------------------------------------------------------------
def _sync_buckets_args(**overrides):
    base = {"admin_port": "3903", "buckets_json": '["label-studio"]', "check": False}
    base.update(overrides)
    return type("A", (), base)()


def _fake_admin(responses):
    """responses: dict {(method, path): value_or_callable(query, body)}.
    A callable lets one endpoint (e.g. CreateBucket, called once per missing
    bucket) return different responses per call; a plain (status, body)
    tuple is enough for endpoints hit at most once (ListBuckets, ListKeys)."""
    calls = []

    def fake(admin_port, admin_token, method, path, query=None, body=None):
        calls.append((method, path, query, body))
        resp = responses[(method, path)]
        return resp(query, body) if callable(resp) else resp

    return fake, calls


def test_sync_buckets_creates_missing(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, []),
            ("POST", "/v2/CreateBucket"): (200, {"id": "b1", "globalAliases": ["label-studio"]}),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_buckets(_sync_buckets_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["buckets_to_create"] == ["label-studio"]
    create_calls = [c for c in calls if c[1] == "/v2/CreateBucket"]
    assert len(create_calls) == 1
    assert create_calls[0][3] == {"globalAlias": "label-studio"}


def test_sync_buckets_no_change_when_present(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    fake, calls = _fake_admin(
        {("GET", "/v2/ListBuckets"): (200, [{"id": "b1", "globalAliases": ["label-studio"]}])}
    )
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_buckets(_sync_buckets_args())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert not any(c[1] == "/v2/CreateBucket" for c in calls)


def test_sync_buckets_check_mode_no_mutation(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    fake, calls = _fake_admin({("GET", "/v2/ListBuckets"): (200, [])})
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_buckets(_sync_buckets_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    assert not any(c[1] == "/v2/CreateBucket" for c in calls)


def test_sync_buckets_fails_clean_when_admin_token_unset(monkeypatch, capsys):
    monkeypatch.delenv("GARAGE_ADMIN_TOKEN", raising=False)
    rc = m.do_sync_buckets(_sync_buckets_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == ["GARAGE_ADMIN_TOKEN"]


def test_sync_buckets_fails_on_non200_listbuckets(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    fake, _calls = _fake_admin({("GET", "/v2/ListBuckets"): (401, {"error": "bad token"})})
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_buckets(_sync_buckets_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")


# --- sync-keys --------------------------------------------------------------------
def _sync_keys_args(**overrides):
    base = {
        "admin_port": "3903",
        "keys_json": json.dumps(
            [
                {
                    "name": "label-studio",
                    "buckets": [{"name": "label-studio", "permissions": ["read", "write"]}],
                }
            ]
        ),
        "keys_dir": "/volume1/docker/garage/keys",
        "check": False,
    }
    base.update(overrides)
    return type("A", (), base)()


_LS_BUCKET = {"id": "b1", "globalAliases": ["label-studio"]}
# The control node provisions these in OpenBao and passes them via
# GARAGE_KEY_CREDENTIALS_JSON; sync-keys IMPORTS from them + renders <name>.env.
_LS_CREDS = {"label-studio": {"access_key_id": "GK1", "secret_access_key": "SUPERSECRETVALUE"}}
_LS_ENV = "ACCESS_KEY_ID=GK1\nSECRET_ACCESS_KEY=SUPERSECRETVALUE\n"


def _set_creds(monkeypatch, mapping=None):
    monkeypatch.setenv(
        "GARAGE_KEY_CREDENTIALS_JSON", json.dumps(_LS_CREDS if mapping is None else mapping)
    )


def test_sync_keys_imports_key_and_grants(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (200, []),
            ("POST", "/v2/ImportKey"): (200, {"accessKeyId": "GK1"}),
            ("POST", "/v2/AllowBucketKey"): (200, {}),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)
    monkeypatch.setattr(m, "_read", lambda p: None)  # .env absent → render it
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))
    monkeypatch.setattr(m.os, "makedirs", lambda p, exist_ok=False: None)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    assert "SUPERSECRETVALUE" not in out  # secret never in the emitted payload

    # Imported with the OpenBao-provided creds (in the JSON body, never argv).
    import_calls = [c for c in calls if c[1] == "/v2/ImportKey"]
    assert len(import_calls) == 1
    assert import_calls[0][3] == {
        "accessKeyId": "GK1",
        "secretAccessKey": "SUPERSECRETVALUE",
        "name": "label-studio",
    }
    assert not any(c[1] == "/v2/CreateKey" for c in calls)  # never server-generates

    assert len(writes) == 1
    path, content, mode = writes[0]
    assert path == os.path.join("/volume1/docker/garage/keys", "label-studio.env")
    assert mode == 0o400
    assert content == _LS_ENV

    allow_calls = [c for c in calls if c[1] == "/v2/AllowBucketKey"]
    assert len(allow_calls) == 1
    assert allow_calls[0][3] == {
        "bucketId": "b1",
        "accessKeyId": "GK1",
        "permissions": {"read": True, "write": True},
    }


def test_sync_keys_no_change_when_key_env_and_grants_match(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (200, [{"id": "GK1", "name": "label-studio"}]),
            ("GET", "/v2/GetBucketInfo"): (
                200,
                {
                    "keys": [
                        {
                            "accessKeyId": "GK1",
                            "permissions": {"read": True, "write": True, "owner": False},
                        }
                    ]
                },
            ),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)
    monkeypatch.setattr(m, "_read", lambda p: _LS_ENV)  # .env already matches OpenBao

    rc = m.do_sync_keys(_sync_keys_args())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert not any(
        c[1] in ("/v2/ImportKey", "/v2/AllowBucketKey", "/v2/DenyBucketKey") for c in calls
    )


def test_sync_keys_revokes_extra_permission(monkeypatch, capsys):
    """Current grant has owner=True, desired is only [read, write] — the sync
    is fully declarative (Deny removes what's not listed), not additive-only."""
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (200, [{"id": "GK1", "name": "label-studio"}]),
            ("GET", "/v2/GetBucketInfo"): (
                200,
                {
                    "keys": [
                        {
                            "accessKeyId": "GK1",
                            "permissions": {"read": True, "write": True, "owner": True},
                        }
                    ]
                },
            ),
            ("POST", "/v2/DenyBucketKey"): (200, {}),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)
    monkeypatch.setattr(m, "_read", lambda p: _LS_ENV)  # .env matches → only grants change
    monkeypatch.setattr(m.os, "makedirs", lambda p, exist_ok=False: None)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    deny_calls = [c for c in calls if c[1] == "/v2/DenyBucketKey"]
    assert len(deny_calls) == 1
    assert deny_calls[0][3] == {
        "bucketId": "b1",
        "accessKeyId": "GK1",
        "permissions": {"owner": True},
    }
    assert not any(c[1] == "/v2/AllowBucketKey" for c in calls)


def test_sync_keys_restores_env_from_openbao_when_missing(monkeypatch, capsys):
    """A key that exists on Garage (id matches OpenBao) but whose local .env is
    gone is RESTORED from OpenBao truth — no rotation, no ImportKey. This is the
    exact drift that used to be an unrecoverable FAIL."""
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (200, [{"id": "GK1", "name": "label-studio"}]),
            ("GET", "/v2/GetBucketInfo"): (
                200,
                {
                    "keys": [
                        {
                            "accessKeyId": "GK1",
                            "permissions": {"read": True, "write": True, "owner": False},
                        }
                    ]
                },
            ),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)
    monkeypatch.setattr(m, "_read", lambda p: None)  # .env missing
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))
    monkeypatch.setattr(m.os, "makedirs", lambda p, exist_ok=False: None)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["keys_to_import"] == []  # key already on Garage — no rotation
    assert payload["env_to_write"] == ["label-studio"]
    assert not any(c[1] in ("/v2/ImportKey", "/v2/CreateKey") for c in calls)
    assert len(writes) == 1 and writes[0][1] == _LS_ENV


def test_sync_keys_fails_on_id_mismatch(monkeypatch, capsys):
    """Key exists on Garage with a different id than OpenBao holds → out-of-band
    rotation. Surface it, don't silently diverge."""
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)  # OpenBao id = GK1
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (200, [{"id": "GKold", "name": "label-studio"}]),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["keys"] == [{"key": "label-studio", "on_garage": "GKold", "in_openbao": "GK1"}]
    assert "out-of-band rotation" in payload["reason"]
    # Must fail BEFORE touching GetBucketInfo / any mutation endpoint.
    assert not any(c[1] == "/v2/GetBucketInfo" for c in calls)


def test_sync_keys_fails_when_credential_missing_for_declared_key(monkeypatch, capsys):
    """The control node must provision every declared key's credential in OpenBao;
    a gap fails loudly rather than importing a half-key."""
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch, {})  # no credential for label-studio
    fake, calls = _fake_admin({("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET])})
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["keys"] == ["label-studio"]
    assert "no credential supplied" in payload["reason"]
    assert not calls  # fails before any admin call


def test_sync_keys_fails_clean_when_credentials_env_unset(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    monkeypatch.delenv("GARAGE_KEY_CREDENTIALS_JSON", raising=False)
    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == ["GARAGE_KEY_CREDENTIALS_JSON"]


def test_sync_keys_fails_on_missing_bucket_reference(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, _calls = _fake_admin({("GET", "/v2/ListBuckets"): (200, [])})
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["bucket"] == "label-studio"
    assert "sync-buckets must run" in payload["reason"]


def test_sync_keys_fails_on_duplicate_key_name(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, _calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (
                200,
                [
                    {"id": "GK1", "name": "label-studio"},
                    {"id": "GK2", "name": "label-studio"},
                ],
            ),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)

    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["name"] == "label-studio"
    assert "duplicate" in payload["reason"]


def test_sync_keys_check_mode_no_mutation(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    fake, calls = _fake_admin(
        {
            ("GET", "/v2/ListBuckets"): (200, [_LS_BUCKET]),
            ("GET", "/v2/ListKeys"): (200, []),
        }
    )
    monkeypatch.setattr(m, "_admin_request", fake)
    monkeypatch.setattr(m, "_read", lambda p: None)
    writes = []
    monkeypatch.setattr(m, "_atomic_write", lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_sync_keys(_sync_keys_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["keys_to_import"] == ["label-studio"]
    assert payload["env_to_write"] == ["label-studio"]
    assert payload["grant_ops"] == [
        {
            "key": "label-studio",
            "bucket": "label-studio",
            "op": "allow",
            "permissions": ["read", "write"],
        }
    ]
    assert writes == []
    assert not any(c[1] in ("/v2/ImportKey", "/v2/AllowBucketKey") for c in calls)


def test_sync_keys_rejects_invalid_permission(monkeypatch, capsys):
    monkeypatch.setenv("GARAGE_ADMIN_TOKEN", "tok" * 16)
    _set_creds(monkeypatch)
    bad_json = json.dumps(
        [
            {
                "name": "label-studio",
                "buckets": [{"name": "label-studio", "permissions": ["read", "delete"]}],
            }
        ]
    )
    rc = m.do_sync_keys(_sync_keys_args(keys_json=bad_json))
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "invalid permission" in payload["reason"]


def test_sync_keys_fails_clean_when_admin_token_unset(monkeypatch, capsys):
    monkeypatch.delenv("GARAGE_ADMIN_TOKEN", raising=False)
    rc = m.do_sync_keys(_sync_keys_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == ["GARAGE_ADMIN_TOKEN"]
