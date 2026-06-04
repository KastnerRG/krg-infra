"""Unit tests for apply_sso.py — run with: pytest (no DSM needed).

Mocks the `_exec` subprocess boundary to drive the OK/WOULD-CHANGE/CHANGED/FAIL
contract, the full-object overlay (unmanaged DSM fields preserved), the
write-only secret handling (from env, never in drift output), and the
"enabled-but-no-secret" fail-fast.

The DSM SSO-Client API name/fields are a documented best-guess (see apply_sso.py
banner); these tests pin the IDEMPOTENCY ENGINE, not the as-yet-unverified field
names — so they stay green after a discovery flip of SSO_API / OIDC_FIELDS.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_sso as m  # noqa: E402


def _live(**overrides):
    """Mirrors a plausible DSM SSO-Client GET, with an unmanaged field
    (`saml_metadata`) to verify the full-object overlay preserves it."""
    base = {
        "enable": False,
        "provider_name": "",
        "app_id": "",
        "well_known_url": "",
        "redirect_uri": "",
        "account_attribute": "",
        "set_as_default": False,
        "saml_metadata": {"untouched": True},   # not managed by the role
    }
    base.update(overrides)
    return base


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


# baseline args that match _live(enable=True, …) so individual tests tweak one field.
_DESIRED = dict(
    enable="true",
    provider_name="Authentik",
    client_id="e4e-nas",
    issuer_url="https://auth.krg.ucsd.edu/application/o/e4e-nas/",
    redirect_uri="https://e4e-nas.ucsd.edu:6021",
    account_attribute="preferred_username",
    set_as_default="true",
)


def _argv(**overrides):
    d = dict(_DESIRED)
    d.update(overrides)
    out = []
    for k, v in d.items():
        out += ["--" + k.replace("_", "-"), v]
    return ["oidc"] + out


def _live_applied():
    """A live GET that already matches _DESIRED (so the engine sees no drift)."""
    return _live(enable=True, provider_name="Authentik", app_id="e4e-nas",
                 well_known_url="https://auth.krg.ucsd.edu/application/o/e4e-nas/",
                 redirect_uri="https://e4e-nas.ucsd.edu:6021",
                 account_attribute="preferred_username", set_as_default=True)


# --- helpers --------------------------------------------------------------------
def test_bool_helper():
    assert m._bool("true") and m._bool("ON") and m._bool("1")
    assert not (m._bool("false") or m._bool("0") or m._bool("off"))


def test_args_from_quotes_bare_strings_and_drops_null():
    args = m._args_from({"s": "https://x/y", "b": True, "n": None, "i": 5})
    assert 's="https://x/y"' in args      # JSON-quoted so DSM gets the exact value
    assert "b=true" in args and "i=5" in args
    assert not any(x.startswith("n=") for x in args)


# --- oidc: contract -------------------------------------------------------------
def test_oidc_no_change(monkeypatch, capsys):
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    monkeypatch.setattr(m, "_exec", _exec_factory(_live_applied()))
    rc = m.main(_argv())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_oidc_would_change_in_check_does_not_set(monkeypatch, capsys):
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_live(), set_capture=sets))
    rc = m.main(_argv() + ["--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    assert sets == []                       # --check must not mutate


def test_oidc_changed_sets_and_preserves_unmanaged(monkeypatch, capsys):
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_live(), set_capture=sets))
    rc = m.main(_argv())
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    assert len(sets) == 1
    _, params = sets[0]
    # unmanaged field carried through the full-object overlay
    assert any(p.startswith("saml_metadata=") for p in params)
    # managed fields present
    assert 'app_id="e4e-nas"' in params
    assert any(p.startswith("set_as_default=") for p in params)


def test_oidc_secret_is_write_only(monkeypatch, capsys):
    """Secret reaches the SET payload but never the drift/stdout."""
    monkeypatch.setenv(m._SECRET_ENV_VAR, "TOPSECRET")
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_live(), set_capture=sets))
    rc = m.main(_argv())
    out = capsys.readouterr().out
    assert rc == 0
    assert "TOPSECRET" not in out                       # never printed
    _, params = sets[0]
    assert any('app_secret="TOPSECRET"' == p for p in params)   # but written


def test_oidc_enabled_without_secret_fails(monkeypatch, capsys):
    monkeypatch.delenv(m._SECRET_ENV_VAR, raising=False)
    monkeypatch.setattr(m, "_exec", _exec_factory(_live()))
    rc = m.main(_argv())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == [m._SECRET_ENV_VAR]


def test_oidc_disabled_needs_no_secret(monkeypatch, capsys):
    """Turning SSO OFF must not require the secret env var."""
    monkeypatch.delenv(m._SECRET_ENV_VAR, raising=False)
    monkeypatch.setattr(m, "_exec", _exec_factory(_live(enable=True), set_capture=[]))
    rc = m.main(["oidc", "--enable", "false"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
