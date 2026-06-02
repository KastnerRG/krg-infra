"""Unit tests for apply_garage.py — pytest, no DSM needed.

The script's three subcommands shell out to (a) the filesystem and (b)
`docker` / `garage` binaries. Tests monkeypatch `_run`, `_read`, and
`_atomic_write` so nothing escapes the test process.
"""
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
        "config_path":         "/volume1/docker/garage/garage.toml",
        "db_engine":           "lmdb",
        "replication_factor":  1,
        "compression_level":   2,
        "rpc_bind_addr":       "[::]:3901",
        "rpc_public_addr":     "127.0.0.1:3901",
        "s3_api_bind_addr":    "[::]:3900",
        "s3_region":           "garage",
        "s3_root_domain":      ".s3.garage.e4e-nas.ucsd.edu",
        "s3_web_bind_addr":    "[::]:3902",
        "s3_web_root_domain":  ".web.garage.e4e-nas.ucsd.edu",
        "s3_web_index":        "index.html",
        "admin_api_bind_addr": "[::]:3903",
        "rpc_secret":          "a" * 64,
        "admin_token":         "b" * 64,
        "metrics_token":       "c" * 64,
        "meta_dir":            "/volume2/s3-data/meta",
        "data_dir":            "/volume2/s3-data/data",
        "check":               False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _deploy_args(**overrides):
    base = {
        "share_path":      "/docker/garage",
        "container_name":  "garage",
        "image":           "dxflrs/garage",
        "image_tag":       "v1.1.0",
        "network_mode":    "host",
        "restart_policy":  "unless-stopped",
        "meta_dir":        "/volume2/s3-data/meta",
        "data_dir":        "/volume2/s3-data/data",
        "config_path":     "/volume1/docker/garage/garage.toml",
        "rust_log":        "garage=info",
        "check":           False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _layout_args(**overrides):
    base = {
        "container_name": "garage",
        "zone":           "dc1",
        "capacity":       "5T",
        "check":          False,
    }
    base.update(overrides)
    return type("A", (), base)()


class _RunResult:
    def __init__(self, rc, stdout="", stderr=""):
        self.returncode = rc
        self.stdout = stdout
        self.stderr = stderr


# --- render-config ------------------------------------------------------------
def test_render_config_writes_when_missing(monkeypatch, capsys):
    monkeypatch.setattr(m, "_read", lambda p: None)
    writes = []
    monkeypatch.setattr(m, "_atomic_write",
                        lambda p, c, mode: writes.append((p, c, mode)))

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
    assert 'root_domain = ".s3.garage.e4e-nas.ucsd.edu"' in content


def test_render_config_no_change_on_identical(monkeypatch, capsys):
    # Pre-render the desired output, hand it back as the existing file content.
    a = _render_args()
    fields = {
        "db_engine": a.db_engine,
        "replication_factor": int(a.replication_factor),
        "compression_level": int(a.compression_level),
        "rpc_bind_addr": a.rpc_bind_addr,
        "rpc_public_addr": a.rpc_public_addr,
        "rpc_secret": a.rpc_secret,
        "s3_api_bind_addr": a.s3_api_bind_addr,
        "s3_region": a.s3_region,
        "s3_root_domain": a.s3_root_domain,
        "s3_web_bind_addr": a.s3_web_bind_addr,
        "s3_web_root_domain": a.s3_web_root_domain,
        "s3_web_index": a.s3_web_index,
        "admin_api_bind_addr": a.admin_api_bind_addr,
        "admin_token": a.admin_token,
        "metrics_token": a.metrics_token,
    }
    existing = m.GARAGE_TOML_TEMPLATE % fields
    monkeypatch.setattr(m, "_read", lambda p: existing)
    writes = []
    monkeypatch.setattr(m, "_atomic_write",
                        lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_render_config(a)
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert writes == []


def test_render_config_check_mode_doesnt_write(monkeypatch, capsys):
    monkeypatch.setattr(m, "_read", lambda p: None)
    writes = []
    monkeypatch.setattr(m, "_atomic_write",
                        lambda p, c, mode: writes.append((p, c, mode)))

    rc = m.do_render_config(_render_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    assert writes == []


def test_render_config_rejects_double_quote_in_secret(monkeypatch, capsys):
    # Defense against TOML literal-break injection — even though the operator
    # generates secrets with openssl, validate at the bottleneck.
    monkeypatch.setattr(m, "_read", lambda p: None)
    rc = m.do_render_config(_render_args(rpc_secret='abc"def'))
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["field"] == "rpc_secret"


def test_render_config_secret_redacted_in_changed_payload(monkeypatch, capsys):
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m, "_atomic_write", lambda *a, **kw: None)
    rc = m.do_render_config(_render_args(rpc_secret="SUPERSECRET" * 4))
    out = capsys.readouterr().out
    assert rc == 0
    assert "SUPERSECRET" not in out


# --- deploy -------------------------------------------------------------------
def test_deploy_no_change(monkeypatch, capsys):
    # Build the desired compose, hand it back as the existing file content.
    a = _deploy_args()
    desired = m.COMPOSE_TEMPLATE % {
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
    monkeypatch.setattr(m, "_read", lambda p: desired)
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(m, "_container_image", lambda n: "dxflrs/garage:v1.1.0")

    rc = m.do_deploy(a)
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_deploy_image_drift_triggers_compose_up(monkeypatch, capsys):
    a = _deploy_args(image_tag="v1.2.0")
    desired_compose = m.COMPOSE_TEMPLATE % {
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
    monkeypatch.setattr(m, "_read", lambda p: desired_compose)  # compose matches
    monkeypatch.setattr(m.os.path, "exists", lambda p: True)
    monkeypatch.setattr(m, "_container_running", lambda n: True)
    monkeypatch.setattr(m, "_container_image", lambda n: "dxflrs/garage:v1.1.0")  # but image drifted

    writes = []
    monkeypatch.setattr(m, "_atomic_write",
                        lambda p, c, mode: writes.append((p, c, mode)))
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


def test_deploy_missing_garage_toml_fails(monkeypatch, capsys):
    a = _deploy_args()
    monkeypatch.setattr(m, "_read", lambda p: None)
    monkeypatch.setattr(m.os.path, "exists", lambda p: False)  # /etc/garage.toml missing

    rc = m.do_deploy(a)
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "render-config" in payload["reason"]


def test_deploy_compose_path_mapping():
    # Share-path → disk-path: /volume1 is the only volume that holds shares
    # whose root has compose dirs in this design.
    assert m._compose_path("/docker/garage") == \
        "/volume1/docker/garage/docker-compose.yml"
    with pytest.raises(ValueError):
        m._compose_path("relative/path")


# --- layout -------------------------------------------------------------------
def test_layout_no_change_when_version_already_assigned(monkeypatch, capsys):
    a = _layout_args()
    outputs = iter([
        _RunResult(0, stdout="==== HEALTHY NODES ====\nabc1234567890def NO ROLE 10.0.0.1\n"),
        _RunResult(0, stdout="Current cluster layout version: 1\nID  Tags Zone Capacity\nabc1 ... dc1 5T\n"),
    ])

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
    outputs = iter([
        _RunResult(0, stdout=status_out),                                    # garage status (probe)
        _RunResult(0, stdout="Current cluster layout version: 0\n"),         # garage layout show
        _RunResult(0, stdout=status_out),                                    # garage status (for node id)
        _RunResult(0, stdout="Role changes staged\n"),                       # garage layout assign
        _RunResult(0, stdout="Layout version 1 applied\n"),                  # garage layout apply
    ])
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
        "==== HEALTHY NODES ====\n"
        f"{full_id}  NO ROLE ASSIGNED  10.0.0.1:3901  garage  HEALTHY\n"
    )
    outputs = iter([
        _RunResult(0, stdout=status_out),                             # probe
        _RunResult(0, stdout="Current cluster layout version: 0\n"),  # show
        _RunResult(0, stdout=status_out),                             # node-id lookup
        _RunResult(0, stdout="staged\n"),                             # assign
        _RunResult(0, stdout="applied\n"),                            # apply
    ])
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
    monkeypatch.setattr(m, "_run",
                        lambda *cmd, **kw: _RunResult(1, stderr="rpc dial err"))

    rc = m.do_layout(a)
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "container not ready" in payload["reason"]


# --- argparse plumbing --------------------------------------------------------
def test_main_dispatches_to_subcommand(monkeypatch, capsys):
    monkeypatch.setattr(m, "do_render_config", lambda a: (print("OK no-change") or 0))
    rc = m.main([
        "render-config",
        "--config-path", "/tmp/x.toml",
        "--db-engine", "lmdb",
        "--replication-factor", "1",
        "--compression-level", "2",
        "--rpc-bind-addr", "[::]:3901",
        "--rpc-public-addr", "127.0.0.1:3901",
        "--s3-api-bind-addr", "[::]:3900",
        "--s3-region", "garage",
        "--s3-root-domain", ".x",
        "--s3-web-bind-addr", "[::]:3902",
        "--s3-web-root-domain", ".y",
        "--s3-web-index", "index.html",
        "--admin-api-bind-addr", "[::]:3903",
        "--rpc-secret", "a" * 32,
        "--admin-token", "b" * 32,
        "--metrics-token", "c" * 32,
        "--meta-dir", "/m", "--data-dir", "/d",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
