"""Unit tests for apply_git_lfs.py — run with: pytest (no DSM needed)."""

import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import apply_git_lfs as m  # noqa: E402


def _config_body(text):
    """Strip the header comments; the rest is JSON."""
    return json.loads("\n".join(line for line in text.splitlines() if not line.startswith("#")))


def _render(tmp_path, *extra, orgs='["UCSD-E4E"]', url="https://lfs.e4e.ucsd.edu"):
    return m.main(
        [
            "render",
            "--config-path",
            str(tmp_path / "giftless.yaml"),
            "--middleware-path",
            str(tmp_path / "krg_public_url.py"),
            "--public-url",
            url,
            "--github-orgs-json",
            orgs,
            *extra,
        ]
    )


@pytest.fixture
def no_chown(monkeypatch):
    # tests don't run as root
    monkeypatch.setattr(m.os, "chown", lambda *a: None)


# --- render -------------------------------------------------------------------
def test_config_restricts_to_orgs_and_disables_preauth():
    cfg = _config_body(m.render_config(["UCSD-E4E"], "https", "lfs.e4e.ucsd.edu"))
    (auth,) = cfg["AUTH_PROVIDERS"]
    assert auth["factory"] == "giftless.auth.github:factory"
    assert auth["options"]["restrict_to"] == {"UCSD-E4E": None}
    # the default JWT pre-auth key is the literal "change-me" — must be off
    assert "PRE_AUTHORIZED_ACTION_PROVIDER" in cfg
    assert cfg["PRE_AUTHORIZED_ACTION_PROVIDER"] is None
    assert cfg["LEGACY_ENDPOINTS"] is False
    opts = cfg["TRANSFER_ADAPTERS"]["basic"]["options"]
    assert opts["storage_class"] == "giftless.storage.local_storage:LocalStorage"
    assert opts["storage_options"]["path"] == m.STORAGE_MOUNT
    (mw,) = cfg["MIDDLEWARE"]
    assert mw == {
        "class": "krg_public_url:FixedPublicURL",
        "kwargs": {"scheme": "https", "host": "lfs.e4e.ucsd.edu"},
    }


def test_config_is_deterministic():
    a = m.render_config(["B", "A"], "https", "h")
    assert a == m.render_config(["B", "A"], "https", "h")


def test_middleware_pins_scheme_and_host():
    ns = {}
    exec(m.MIDDLEWARE_SOURCE, ns)
    seen = {}

    def app(environ, start_response):
        seen.update(environ)
        return [b"ok"]

    mw = ns["FixedPublicURL"](app, scheme="https", host="lfs.e4e.ucsd.edu")
    assert mw({"wsgi.url_scheme": "http", "HTTP_HOST": "127.0.0.1:8090"}, None) == [b"ok"]
    assert seen["wsgi.url_scheme"] == "https"
    assert seen["HTTP_HOST"] == "lfs.e4e.ucsd.edu"


@pytest.mark.parametrize(
    "url",
    ["http://lfs.e4e.ucsd.edu", "https://", "https://lfs.e4e.ucsd.edu/sub", "lfs.e4e.ucsd.edu"],
)
def test_render_refuses_bad_public_url(tmp_path, capsys, url):
    assert _render(tmp_path, url=url) == 1
    assert capsys.readouterr().out.startswith("FAIL ")
    assert not (tmp_path / "giftless.yaml").exists()


def test_public_url_keeps_explicit_port():
    assert m._parse_public_url("https://s3.e4e.ucsd.edu:8443") == ("https", "s3.e4e.ucsd.edu:8443")


@pytest.mark.parametrize("orgs", ["[]", '[""]', '"UCSD-E4E"', "nope"])
def test_render_refuses_missing_org_restriction(tmp_path, capsys, orgs):
    assert _render(tmp_path, orgs=orgs) == 1
    assert capsys.readouterr().out.startswith("FAIL ")


def test_render_check_writes_nothing(tmp_path, capsys):
    assert _render(tmp_path, "--check") == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE ")
    assert not (tmp_path / "giftless.yaml").exists()


def test_render_then_idempotent(tmp_path, capsys, no_chown):
    assert _render(tmp_path) == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED ")
    assert len(json.loads(out.split(" ", 1)[1])["files"]) == 2
    assert _render(tmp_path) == 0
    assert capsys.readouterr().out.strip() == "OK no-change"


# --- deploy -------------------------------------------------------------------
class FakeDocker:
    def __init__(self, image=None, running=False, rc=0):
        self.image, self.running, self.rc = image, running, rc
        self.calls = []

    def __call__(self, *cmd, **kw):
        self.calls.append(cmd)
        if cmd[:2] == ("docker", "inspect"):
            if self.image is None:
                return subprocess.CompletedProcess(cmd, 1, "", "no such object")
            out = self.image if "{{.Config.Image}}" in cmd else str(self.running).lower()
            return subprocess.CompletedProcess(cmd, 0, out + "\n", "")
        return subprocess.CompletedProcess(cmd, self.rc, "", "boom" if self.rc else "")

    @property
    def compose_ops(self):
        return [c[4] for c in self.calls if c[:2] == ("docker", "compose")]


def _deploy_argv(tmp_path, *extra):
    return [
        "deploy",
        "--compose-path",
        str(tmp_path / "docker-compose.yml"),
        "--container-name",
        "giftless",
        "--image",
        "datopian/giftless",
        "--image-tag",
        "0.6.2",
        "--restart-policy",
        "unless-stopped",
        "--config-path",
        str(tmp_path / "giftless.yaml"),
        "--middleware-path",
        str(tmp_path / "krg_public_url.py"),
        "--storage-dir",
        str(tmp_path / "store" / "giftless"),
        "--bind-host",
        "127.0.0.1",
        "--port",
        "8090",
        "--processes",
        "2",
        "--threads",
        "8",
        *extra,
    ]


@pytest.fixture
def rendered(tmp_path, no_chown, capsys):
    assert _render(tmp_path) == 0
    capsys.readouterr()
    return tmp_path


def test_deploy_fails_without_rendered_files(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(m, "_run", FakeDocker())
    assert m.main(_deploy_argv(tmp_path)) == 1
    assert capsys.readouterr().out.startswith("FAIL ")


def test_deploy_check_without_rendered_files_is_would_change(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(m, "_run", FakeDocker())
    assert m.main(_deploy_argv(tmp_path, "--check")) == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE ")


def test_deploy_fresh_creates_storage_and_ups(rendered, capsys, monkeypatch):
    fake = FakeDocker()
    monkeypatch.setattr(m, "_run", fake)
    assert m.main(_deploy_argv(rendered)) == 0
    assert capsys.readouterr().out.startswith("CHANGED ")
    assert (rendered / "store" / "giftless").is_dir()
    assert fake.compose_ops == ["up"]
    compose = (rendered / "docker-compose.yml").read_text()
    assert "image: datopian/giftless:0.6.2" in compose
    assert '"--http-socket", "127.0.0.1:8090"' in compose
    assert "%s:/lfs-storage" % (rendered / "store" / "giftless") in compose
    assert "krg_public_url.py:/opt/krg/krg_public_url.py:ro" in compose
    assert "cap_drop: [ALL]" in compose


def test_deploy_check_writes_nothing(rendered, capsys, monkeypatch):
    fake = FakeDocker()
    monkeypatch.setattr(m, "_run", fake)
    assert m.main(_deploy_argv(rendered, "--check")) == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE ")
    assert not (rendered / "docker-compose.yml").exists()
    assert not (rendered / "store").exists()
    assert fake.compose_ops == []


def _converged(rendered, monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", FakeDocker())
    m.main(_deploy_argv(rendered))
    capsys.readouterr()
    fake = FakeDocker(image="datopian/giftless:0.6.2", running=True)
    monkeypatch.setattr(m, "_run", fake)
    return fake


def test_deploy_no_change_when_converged(rendered, capsys, monkeypatch):
    fake = _converged(rendered, monkeypatch, capsys)
    assert m.main(_deploy_argv(rendered)) == 0
    assert capsys.readouterr().out.strip() == "OK no-change"
    assert fake.compose_ops == []


def test_deploy_config_change_restarts(rendered, capsys, monkeypatch):
    fake = _converged(rendered, monkeypatch, capsys)
    assert m.main(_deploy_argv(rendered, "--config-changed")) == 0
    assert capsys.readouterr().out.startswith("CHANGED ")
    assert fake.compose_ops == ["restart"]


def test_deploy_image_bump_recreates(rendered, capsys, monkeypatch):
    _converged(rendered, monkeypatch, capsys)
    fake = FakeDocker(image="datopian/giftless:0.6.1", running=True)
    monkeypatch.setattr(m, "_run", fake)
    assert m.main(_deploy_argv(rendered)) == 0
    assert fake.compose_ops == ["up"]


def test_deploy_compose_failure_is_fail(rendered, capsys, monkeypatch):
    monkeypatch.setattr(m, "_run", FakeDocker(rc=1))
    assert m.main(_deploy_argv(rendered)) == 1
    assert capsys.readouterr().out.startswith("FAIL ")
