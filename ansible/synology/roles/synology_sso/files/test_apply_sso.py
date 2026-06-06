"""Unit tests for apply_sso.py — run with: pytest (no DSM needed).

Mocks the `_exec` subprocess boundary to drive the OK/WOULD-CHANGE/CHANGED/FAIL
contract across the TWO DSM APIs the role drives (SYNO.Core.Directory.OIDC.SSO +
SYNO.Core.Directory.SSO.Setting): independent per-API drift, the partial OIDC set
with profile="oidc", the write-only secret (from env, value never printed,
rotation detected silently), and the enabled-but-no-secret fail-fast.

The API shape/fields were verified from a DevTools capture of the SSO Client
wizard (see apply_sso.py header).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_sso as m  # noqa: E402


# --- live-GET fixtures ----------------------------------------------------------
def _oidc_live(**overrides):
    """A SYNO.Core.Directory.OIDC.SSO get. Includes the DSM-derived endpoint
    fields (which the role does NOT manage) to prove they're left alone."""
    base = {
        "oidc_allow_local_user": False,
        "oidc_authorization_endpoint": "",   # derived by DSM; unmanaged
        "oidc_client_id": "",
        "oidc_client_secret": "",
        "oidc_name": "",
        "oidc_redirect_uri": "",
        "oidc_scope": "",
        "oidc_token_endpoint": "",           # derived by DSM; unmanaged
        "oidc_user_claim": "",
        "oidc_wellknown": "",
    }
    base.update(overrides)
    return base


def _setting_live(default_login=False):
    return {m.DEFAULT_LOGIN_FIELD: default_login}


def _master_live(enable=False):
    # The SYNO.Core.Directory.SSO object — appid/host are for the Synology-SSO
    # profile type (unmanaged here); enable_sso is the master service switch.
    return {"appid": "", m.ENABLE_FIELD: enable, "host": "", "pingpong": None,
            m.DEFAULT_LOGIN_FIELD: enable}


def _exec_factory(oidc_get, master_get, setting_get, set_capture=None):
    gets = {m.OIDC_API: oidc_get, m.MASTER_API: master_get, m.SETTING_API: setting_get}

    def fake(api, version, method, *params):
        if method == "get":
            return {"data": dict(gets[api]), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


# Desired spec (matches what tasks/main.yml passes). _WELLKNOWN is the derived
# discovery URL (issuer + /.well-known/openid-configuration).
_WELLKNOWN = "https://auth.krg.ucsd.edu/application/o/e4e-nas/.well-known/openid-configuration"
_DESIRED = dict(
    enable="true",
    provider_name="Authentik",
    wellknown=_WELLKNOWN,
    client_id="e4e-nas",
    redirect_uri="https://e4e-nas.ucsd.edu:6021",
    scope="openid profile email",
    account_attribute="preferred_username",
    allow_local_user="true",
    set_as_default="true",
)


def _argv(**overrides):
    d = dict(_DESIRED)
    d.update(overrides)
    out = []
    for k, v in d.items():
        out += ["--" + k.replace("_", "-"), v]
    return ["oidc"] + out


def _oidc_applied():
    """An OIDC GET already matching _DESIRED (engine sees no profile drift)."""
    return _oidc_live(oidc_allow_local_user=True, oidc_client_id="e4e-nas",
                      oidc_client_secret="s3cr3t", oidc_name="Authentik",
                      oidc_redirect_uri="https://e4e-nas.ucsd.edu:6021",
                      oidc_scope="openid profile email",
                      oidc_user_claim="preferred_username", oidc_wellknown=_WELLKNOWN)


def _params_to_dict(params):
    return dict(p.split("=", 1) for p in params)


# --- helpers --------------------------------------------------------------------
def test_bool_helper():
    assert m._bool("true") and m._bool("ON") and m._bool("1")
    assert not (m._bool("false") or m._bool("0") or m._bool("off"))


def test_args_from_quotes_strings_bools_and_drops_null():
    args = m._args_from({"s": "https://x/y", "b": True, "f": False, "n": None, "i": 5})
    assert 's="https://x/y"' in args      # JSON-quoted so DSM gets the exact value
    assert "b=true" in args and "f=false" in args and "i=5" in args
    assert not any(x.startswith("n=") for x in args)


# --- oidc: contract -------------------------------------------------------------
def test_oidc_no_change(monkeypatch, capsys):
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    monkeypatch.setattr(m, "_exec",
                        _exec_factory(_oidc_applied(), _master_live(True), _setting_live(True)))
    rc = m.main(_argv())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_oidc_would_change_in_check_does_not_set(monkeypatch, capsys):
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_oidc_live(), _master_live(), _setting_live(), set_capture=sets))
    rc = m.main(_argv() + ["--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    assert sets == []                       # --check must not mutate


def test_oidc_changed_sets_profile_master_and_setting(monkeypatch, capsys):
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_oidc_live(), _master_live(), _setting_live(), set_capture=sets))
    rc = m.main(_argv())
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    apis = [api for api, _ in sets]
    assert m.OIDC_API in apis and m.MASTER_API in apis and m.SETTING_API in apis
    # OIDC set selects + activates the profile, and carries the managed fields;
    # it must NOT send the DSM-derived endpoint fields.
    oidc_params = _params_to_dict(next(p for api, p in sets if api == m.OIDC_API))
    assert oidc_params["profile"] == '"oidc"'
    assert oidc_params["oidc_client_id"] == '"e4e-nas"'
    assert oidc_params["oidc_allow_local_user"] == "true"
    assert "oidc_authorization_endpoint" not in oidc_params
    assert "oidc_token_endpoint" not in oidc_params
    # Master set flips the SSO-service switch on.
    master_params = _params_to_dict(next(p for api, p in sets if api == m.MASTER_API))
    assert master_params[m.ENABLE_FIELD] == "true"
    # Setting set carries the default-login toggle.
    setting_params = _params_to_dict(next(p for api, p in sets if api == m.SETTING_API))
    assert setting_params[m.DEFAULT_LOGIN_FIELD] == "true"
    # Profile is configured BEFORE the service is enabled.
    assert apis.index(m.OIDC_API) < apis.index(m.MASTER_API)


def test_oidc_secret_is_write_only(monkeypatch, capsys):
    """Secret reaches the OIDC set payload but never the drift/stdout."""
    monkeypatch.setenv(m._SECRET_ENV_VAR, "TOPSECRET")
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_oidc_live(), _master_live(), _setting_live(), set_capture=sets))
    rc = m.main(_argv())
    out = capsys.readouterr().out
    assert rc == 0
    assert "TOPSECRET" not in out                       # never printed
    oidc_params = _params_to_dict(next(p for api, p in sets if api == m.OIDC_API))
    assert oidc_params[m._SECRET_FIELD] == '"TOPSECRET"'   # but written


def test_secret_rotation_triggers_oidc_set_only(monkeypatch, capsys):
    """OIDC fields + default-login already match, but the secret differs:
    the OIDC set fires (drift redacted to <changed>), the Setting set does not."""
    monkeypatch.setenv(m._SECRET_ENV_VAR, "newsecret")
    sets = []
    live = _oidc_applied()              # has oidc_client_secret="s3cr3t"
    monkeypatch.setattr(m, "_exec",
                        _exec_factory(live, _master_live(True), _setting_live(True), set_capture=sets))
    rc = m.main(_argv())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    assert "newsecret" not in out and "s3cr3t" not in out
    assert "<changed>" in out
    apis = [api for api, _ in sets]
    assert apis == [m.OIDC_API]         # only OIDC re-set; master/default untouched


def test_default_login_only_drift_sets_setting_only(monkeypatch, capsys):
    """OIDC profile + secret already correct, only the default-login toggle
    differs: just the Setting API is set (OIDC profile not rewritten)."""
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    sets = []
    monkeypatch.setattr(m, "_exec",
                        _exec_factory(_oidc_applied(), _master_live(True), _setting_live(False),
                                      set_capture=sets))
    rc = m.main(_argv())
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    apis = [api for api, _ in sets]
    assert apis == [m.SETTING_API]


def test_master_enable_only_drift_enables_service(monkeypatch, capsys):
    """The exact bug we hit: profile + default-login already correct, but the SSO
    service is off (enable_sso=False) -> only the master set fires (enable_sso=true),
    which is what makes DSM render the login button."""
    monkeypatch.setenv(m._SECRET_ENV_VAR, "s3cr3t")
    sets = []
    monkeypatch.setattr(m, "_exec",
                        _exec_factory(_oidc_applied(), _master_live(False), _setting_live(True),
                                      set_capture=sets))
    rc = m.main(_argv())
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    apis = [api for api, _ in sets]
    assert apis == [m.MASTER_API]
    master_params = _params_to_dict(sets[0][1])
    assert master_params[m.ENABLE_FIELD] == "true"


def test_oidc_enabled_without_secret_fails(monkeypatch, capsys):
    monkeypatch.delenv(m._SECRET_ENV_VAR, raising=False)
    monkeypatch.setattr(m, "_exec", _exec_factory(_oidc_live(), _master_live(), _setting_live()))
    rc = m.main(_argv())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["vars"] == [m._SECRET_ENV_VAR]


def test_oidc_disabled_is_noop_without_secret(monkeypatch, capsys):
    """enable=false: leave DSM untouched, require no secret, fire no SET."""
    monkeypatch.delenv(m._SECRET_ENV_VAR, raising=False)
    sets = []
    monkeypatch.setattr(m, "_exec", _exec_factory(_oidc_live(), _master_live(), _setting_live(), set_capture=sets))
    rc = m.main(["oidc", "--enable", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert sets == []
