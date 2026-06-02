"""Unit tests for apply_users.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_users as m  # noqa: E402


def _factory(live, silently_drop=None):
    """Build a fake _exec.

    SET calls update the simulated live[api]["get"] state so that any
    subsequent GET (e.g. do_home's verify-after-set re-GET) returns the
    new state — matching how a real DSM behaves.

    `silently_drop`: optional set of (api, key) tuples. When a SET would
    set one of those keys, the fake KEEPS the old value on the verify-GET
    — simulating DSM's silent-success-no-persist behaviour (e.g. User.Home
    `enable_domain=true` post-join when winbind isn't ready). The script's
    verify-after-set defer logic should detect this and report no-change.

    The AD-probe (DIRECTORY_DOMAIN_API GET) is called by do_home before
    any User.Home work; default to "joined" so existing tests aren't
    accidentally gated.
    """
    silently_drop = set(silently_drop or [])
    captured = []
    live = {api: {**v, "get": dict(v["get"])} for api, v in live.items()}
    if m.DIRECTORY_DOMAIN_API not in live:
        live[m.DIRECTORY_DOMAIN_API] = {"get": {"enable_domain": True}}

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        # Parse Input envelope OR flat key=val args, apply to live state.
        new_fields = {}
        for p in params:
            if p.startswith("Input="):
                try:
                    new_fields.update(json.loads(p[len("Input="):]))
                except (ValueError, TypeError):
                    pass
            elif "=" in p and not p.startswith(("api=", "version=", "method=")):
                k, v = p.split("=", 1)
                # JSON-decode the value (since _args_from quotes strings)
                try:
                    new_fields[k] = json.loads(v)
                except (ValueError, TypeError):
                    new_fields[k] = v
        if api in live:
            for k, v in new_fields.items():
                if (api, k) in silently_drop:
                    continue  # simulate DSM's silent-drop on this field
                live[api]["get"][k] = v
        return {"success": True}

    return fake, captured


def _home_input(captured):
    """Extract the User.Home.set Input envelope dict from a captured call.
    DSM 7.3 requires User.Home.set params wrapped in Input (validated
    2026-06-01)."""
    set_call = next(p for a, p in captured
                    if a == m.HOME_API and "method=set" in p)
    iarg = next(p for p in set_call if p.startswith("Input="))
    return json.loads(iarg[len("Input="):])


# --- home (SYNO.Core.User.Home) -----------------------------------------------
def test_home_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.HOME_API: {"get": {
        "enable": True,
        "enable_domain": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_home_drift_enables(monkeypatch, capsys):
    """SET goes via Input envelope (DSM 7.3 requirement); verify-after-set
    sees the new live state via the factory's SET-updates-live behavior."""
    fake, captured = _factory({m.HOME_API: {"get": {
        "enable": False,
        "enable_domain": False,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    payload = _home_input(captured)
    assert payload["enable"] is True
    assert payload["enable_domain"] is True


def test_home_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.HOME_API: {"get": {
        "enable": False, "enable_domain": False,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true", "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.HOME_API and "method=set" in p for a, p in captured)


def test_home_preserves_unmanaged_keys(monkeypatch, capsys):
    fake, captured = _factory({m.HOME_API: {"get": {
        "enable": False, "enable_domain": False,
        "home_quota_default": "10GB",   # unmanaged
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    capsys.readouterr()
    # Unmanaged key round-trips inside the Input envelope, not as flat arg
    assert _home_input(captured)["home_quota_default"] == "10GB"


# --- AD-aware gate on enable_domain (DSM err 3103 when not joined) ----------
def test_home_ad_not_joined_pins_enable_domain_to_current(monkeypatch, capsys):
    """When AD isn't joined and spec asks for include_domain_users=true,
    DSM would return err 3103 on the SET. Gate forces desired to match
    current (no drift on that field) and emits a WARN line on stderr."""
    fake, captured = _factory({
        m.HOME_API: {"get": {"enable": True, "enable_domain": False}},
        m.DIRECTORY_DOMAIN_API: {"get": {"enable_domain": False}},  # NOT joined
    })
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    captured_out = capsys.readouterr()
    # No drift (current matches gated desired) -> OK no-change
    assert "OK no-change" in captured_out.out
    # WARN visible on stderr
    assert "deferred" in captured_out.err
    assert "AD-joined" in captured_out.err
    # No SET call attempted
    assert not any(a == m.HOME_API and "method=set" in p for a, p in captured)


def test_home_ad_joined_applies_enable_domain_normally(monkeypatch, capsys):
    """When AD IS joined AND DSM accepts enable_domain=true (verify-GET
    sees the new value), the gate is inert — enable_domain=true flows
    through the Input envelope to the SET payload."""
    fake, captured = _factory({
        m.HOME_API: {"get": {"enable": True, "enable_domain": False}},
        m.DIRECTORY_DOMAIN_API: {"get": {"enable_domain": True}},  # joined
    })
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    assert _home_input(captured)["enable_domain"] is True


def test_home_set_silently_dropped_reports_no_change(monkeypatch, capsys):
    """DSM 7.3 post-join can silently drop enable_domain=true on User.Home
    (SET returns success=true but verify-GET shows the field unchanged —
    validated 2026-06-01 on e4e-nas). do_home must detect this and report
    OK no-change (deferred) instead of CHANGED, otherwise every apply
    would falsely report drift forever."""
    fake, captured = _factory(
        {m.HOME_API: {"get": {"enable": True, "enable_domain": False}}},
        silently_drop={(m.HOME_API, "enable_domain")},
    )
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    out_err = capsys.readouterr()
    # SET attempted (the Input envelope went through)
    assert any(a == m.HOME_API and "method=set" in p for a, p in captured)
    # …but DSM silently dropped enable_domain — script reports no-change
    assert "OK no-change" in out_err.out
    assert "silently dropped" in out_err.out or "silently dropped" in out_err.err
    assert "enable_domain" in out_err.out or "enable_domain" in out_err.err


def test_home_ad_probe_failure_pins_conservatively(monkeypatch, capsys):
    """If the AD-state probe itself raises (DSM down, namespace gone),
    treat as 'not joined' (don't gamble on enable_domain=true → err 3103
    halting the play). The home set should no-op when current matches."""
    def fake(api, *params):
        if api == m.DIRECTORY_DOMAIN_API:
            raise RuntimeError("probe blew up — pretend DSM is mid-restart")
        if api == m.HOME_API and "method=get" in params:
            return {"data": {"enable": True, "enable_domain": False}, "success": True}
        return {"success": True}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    captured_out = capsys.readouterr()
    assert "OK no-change" in captured_out.out
    assert "deferred" in captured_out.err  # WARN emitted (conservative treat-as-not-joined)


def test_home_ad_not_joined_with_already_enabled_enable_domain_is_noop(monkeypatch, capsys):
    """Edge case: AD not joined but DSM already has enable_domain=true
    (e.g. earlier join + later un-join). Gate pins to current=true, so
    desired matches current → no drift → no SET attempted → no err 3103."""
    fake, captured = _factory({
        m.HOME_API: {"get": {"enable": True, "enable_domain": True}},
        m.DIRECTORY_DOMAIN_API: {"get": {"enable_domain": False}},
    })
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "true"])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out
    assert not any(a == m.HOME_API and "method=set" in p for a, p in captured)


def test_home_ad_not_joined_but_spec_false_is_unaffected(monkeypatch, capsys):
    """When spec asks for include_domain_users=false, the gate must not
    fire (nothing to defer). The SET proceeds via the Input envelope."""
    fake, captured = _factory({
        m.HOME_API: {"get": {"enable": False, "enable_domain": False}},
        m.DIRECTORY_DOMAIN_API: {"get": {"enable_domain": False}},
    })
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["home", "--enable", "true", "--include-domain-users", "false"])
    assert rc == 0
    captured_out = capsys.readouterr()
    assert captured_out.out.startswith("CHANGED")
    assert "deferred" not in captured_out.err  # no WARN
    payload = _home_input(captured)
    assert payload["enable"] is True
    assert payload["enable_domain"] is False


# --- authorized-keys ----------------------------------------------------------
def _fake_pwnam(monkeypatch, tmp_path, name="krg-admin"):
    class FakePw:
        pw_name = name
        pw_uid = os.getuid()
        pw_gid = os.getgid()
        pw_dir = str(tmp_path)

    monkeypatch.setattr(m.pwd, "getpwnam", lambda u: FakePw())


def test_keys_creates_dir_and_file(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["ssh-ed25519 AAAA chris@a", "ssh-ed25519 BBBB chris@b"]
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys),
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    auth = tmp_path / ".ssh" / "authorized_keys"
    assert auth.exists()
    written = auth.read_text()
    for k in keys:
        assert k in written
    # Trailing newline + 0600 perms
    assert written.endswith("\n")
    assert (auth.stat().st_mode & 0o777) == 0o600
    assert (tmp_path / ".ssh").stat().st_mode & 0o777 == 0o700


def test_keys_idempotent(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["ssh-ed25519 AAAA a@x"]
    m.main(["authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys)])
    capsys.readouterr()
    rc = m.main(["authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys)])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out


def test_keys_dedupes_and_strips(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["  ssh-ed25519 AAAA a@x  ", "ssh-ed25519 AAAA a@x", "", "ssh-ed25519 BBBB b@y"]
    m.main(["authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys)])
    capsys.readouterr()
    written = (tmp_path / ".ssh" / "authorized_keys").read_text()
    # exactly two entries (deduped, blank dropped, leading/trailing ws stripped)
    assert written == "ssh-ed25519 AAAA a@x\nssh-ed25519 BBBB b@y\n"


def test_keys_check_mode_does_not_write(monkeypatch, capsys, tmp_path):
    _fake_pwnam(monkeypatch, tmp_path)
    keys = ["ssh-ed25519 AAAA a@x"]
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys", json.dumps(keys), "--check",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not (tmp_path / ".ssh" / "authorized_keys").exists()


def test_keys_empty_list_leaves_existing_alone(monkeypatch, capsys, tmp_path):
    """Per the role design, empty desired keys is a no-op (we don't claim
    exclusive ownership). Mirrors ansible.posix.authorized_key exclusive=false."""
    _fake_pwnam(monkeypatch, tmp_path)
    # Seed an existing file
    ssh = tmp_path / ".ssh"
    ssh.mkdir(mode=0o700)
    (ssh / "authorized_keys").write_text("ssh-ed25519 ZZZ external@key\n")
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys", "[]",
    ])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out
    # Existing keys preserved
    assert (ssh / "authorized_keys").read_text() == "ssh-ed25519 ZZZ external@key\n"


def test_keys_missing_user_is_noop(monkeypatch, capsys, tmp_path):
    def raises(_):
        raise KeyError("missing")
    monkeypatch.setattr(m.pwd, "getpwnam", raises)
    rc = m.main([
        "authorized-keys", "--username", "ghost", "--keys", json.dumps(["ssh-ed25519 AAAA x"]),
    ])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out


def test_keys_invalid_json_errors():
    try:
        m.main(["authorized-keys", "--username", "x", "--keys", "not json"])
    except SystemExit as e:
        assert "--keys" in str(e) or "must be a JSON" in str(e)
    else:
        assert False, "should have raised SystemExit"


# --- --keys-b64 (shell-safe variant used by the ansible role) ---------------
import base64 as _b64    # noqa: E402


def test_keys_b64_equivalent_to_keys(monkeypatch, capsys, tmp_path):
    """--keys-b64 must produce the same result as --keys for the same payload."""
    _fake_pwnam(monkeypatch, tmp_path)
    payload = ["ssh-ed25519 AAAA chris@laptop", "ssh-ed25519 BBBB shperry@x"]
    b64 = _b64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys-b64", b64,
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    written = (tmp_path / ".ssh" / "authorized_keys").read_text()
    assert "chris@laptop" in written
    assert "shperry@x" in written


def test_keys_b64_handles_keys_with_spaces_and_quotes(monkeypatch, capsys, tmp_path):
    """Regression for the shell-quoting bug discovered on prod bring-up:
    keys contain SPACES (algo / base64 / comment) AND double-quotes (from JSON);
    bare --keys breaks when transported through ssh + remote sh word-splitter.
    --keys-b64 must survive any shell because base64 has no shell-special chars."""
    _fake_pwnam(monkeypatch, tmp_path)
    payload = [
        'ssh-ed25519 AAAA user@host with spaces',
        'ssh-rsa BBBB "weird" comment',
    ]
    b64 = _b64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    rc = m.main([
        "authorized-keys", "--username", "krg-admin", "--keys-b64", b64,
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    written = (tmp_path / ".ssh" / "authorized_keys").read_text()
    assert "user@host with spaces" in written
    assert 'ssh-rsa BBBB "weird" comment' in written


def test_keys_b64_invalid_base64_errors():
    try:
        m.main(["authorized-keys", "--username", "x", "--keys-b64", "not!valid@base64"])
    except SystemExit as e:
        assert "--keys-b64" in str(e) or "base64" in str(e).lower()
    else:
        assert False, "should have raised SystemExit"


def test_keys_b64_valid_base64_but_invalid_json_errors():
    bad = _b64.b64encode(b"not actually json").decode("ascii")
    try:
        m.main(["authorized-keys", "--username", "x", "--keys-b64", bad])
    except SystemExit as e:
        assert "JSON" in str(e) or "list" in str(e)
    else:
        assert False, "should have raised SystemExit"


def test_keys_and_keys_b64_are_mutually_exclusive():
    """argparse should reject passing both."""
    try:
        m.main([
            "authorized-keys", "--username", "x",
            "--keys", "[]",
            "--keys-b64", _b64.b64encode(b"[]").decode("ascii"),
        ])
    except SystemExit:
        pass  # argparse exits on mutually-exclusive violation
    else:
        assert False, "should have rejected both flags together"
