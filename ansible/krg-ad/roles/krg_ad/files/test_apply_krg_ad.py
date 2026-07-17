"""Unit tests for apply_krg_ad.py — pure logic + subcommand flow (mocked samba-tool).

Run: python3 -m pytest ansible/krg-ad/roles/krg_ad/files/test_apply_krg_ad.py
No directory / samba-tool access required; `run()` is monkeypatched.

NB: module name is apply_krg_ad (not apply_ad) — ansible/synology/ already ships
an unrelated apply_ad.py (DSM AD join), and pytest's rootdir import mode cannot
collect two modules of the same basename. Aliased to apply_ad here so the body
reads naturally.
"""

import json

import apply_krg_ad as apply_ad
import pytest

# Live sample captured from krg-ldap 2026-06-17 (read-only).
LIVE_PWD_SHOW = """\
Password information for domain 'DC=krg,DC=local'

Password complexity: on
Store plaintext passwords: off
Password history length: 24
Minimum password length: 7
Minimum password age (days): 1
Maximum password age (days): 42
Account lockout duration (mins): 30
Account lockout threshold (attempts): 0
Reset account lockout after (mins): 30
"""

AUTHENTIK_SID = "S-1-5-21-2690282619-2128897885-3821334792-1111"
RESET_GUID = apply_ad.RIGHTS["reset-password"]


# ── parse_pwd_settings ─────────────────────────────────────────────────────────
def test_parse_pwd_settings():
    got = apply_ad.parse_pwd_settings(LIVE_PWD_SHOW)
    assert got == {
        "complexity": "on",
        "history_length": 24,
        "min_pwd_length": 7,
        "min_pwd_age": 1,
        "max_pwd_age": 42,
    }


# ── pwd_policy_diff / pwd_set_flags ────────────────────────────────────────────
def test_pwd_policy_diff_detects_expiry_and_length():
    live = apply_ad.parse_pwd_settings(LIVE_PWD_SHOW)
    desired = {
        "max_pwd_age": 0,
        "min_pwd_length": 12,
        "complexity": "on",
        "history_length": 24,
        "min_pwd_age": 1,
    }
    diffs = dict((k, (h, w)) for k, h, w in apply_ad.pwd_policy_diff(desired, live))
    # complexity/history/min_age already match -> not in diff; expiry+length do.
    assert set(diffs) == {"max_pwd_age", "min_pwd_length"}
    assert diffs["max_pwd_age"] == (42, 0)
    assert diffs["min_pwd_length"] == (7, 12)


def test_pwd_policy_diff_empty_when_converged():
    live = {"max_pwd_age": 0, "min_pwd_length": 12, "complexity": "on"}
    desired = {"max_pwd_age": 0, "min_pwd_length": 12, "complexity": "on"}
    assert apply_ad.pwd_policy_diff(desired, live) == []


def test_pwd_set_flags():
    desired = {"max_pwd_age": 0, "min_pwd_length": 12}
    diffs = [("max_pwd_age", 42, 0), ("min_pwd_length", 7, 12)]
    assert apply_ad.pwd_set_flags(diffs, desired) == [
        "--max-pwd-age=0",
        "--min-pwd-length=12",
    ]


# ── name list parsing ──────────────────────────────────────────────────────────
def test_parse_name_list():
    assert apply_ad.parse_name_list("GPU Users\nWaiter\n\n  Docker Users \n") == {
        "GPU Users",
        "Waiter",
        "Docker Users",
    }


# ── SDDL build + presence detection ────────────────────────────────────────────
def test_build_ace_child_users():
    ace = apply_ad.build_ace("child-users", RESET_GUID, AUTHENTIK_SID)
    assert ace == "(OA;CI;CR;{};;{})".format(RESET_GUID, AUTHENTIK_SID)


def test_ace_present_true_and_inheritance_agnostic():
    sddl = "O:DAG:DAD:(A;;RPWP;;;DA)(OA;CIIO;CR;{};;{})(A;;LC;;;WD)".format(
        RESET_GUID, AUTHENTIK_SID
    )
    # different inheritance flags (CIIO vs CI) must still count as present
    assert apply_ad.ace_present(sddl, RESET_GUID, AUTHENTIK_SID) is True


def test_ace_present_false_when_other_sid():
    other = "S-1-5-21-2690282619-2128897885-3821334792-9999"
    sddl = "D:(OA;CI;CR;{};;{})".format(RESET_GUID, other)
    assert apply_ad.ace_present(sddl, RESET_GUID, AUTHENTIK_SID) is False


def test_ace_present_false_when_right_absent():
    sddl = "D:(A;;RPWP;;;{})".format(AUTHENTIK_SID)
    assert apply_ad.ace_present(sddl, RESET_GUID, AUTHENTIK_SID) is False


# ── subcommand flow with a mocked samba-tool ───────────────────────────────────
class FakeSamba:
    """Records calls and replies from a scripted (argstuple -> (rc,out,err)) map."""

    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        for prefix, resp in self.replies.items():
            if args[: len(prefix)] == prefix:
                return resp
        return (0, "", "")


def _plan_file(tmp_path, obj):
    p = tmp_path / "plan.json"
    p.write_text(json.dumps(obj))
    return str(p)


def test_groups_creates_only_missing(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("group", "list"): (0, "Waiter\nGPU Users\nDomain Admins\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {
        "container": "CN=Users,DC=krg,DC=local",
        "groups": [
            {"name": "Waiter"},  # exists -> skip
            {"name": "fuzzy", "description": "x"},  # missing -> create
            {"name": "skipme", "skip": True},  # skipped entirely
        ],
    }
    with pytest.raises(SystemExit) as e:
        apply_ad.main(["groups", "--plan", _plan_file(tmp_path, plan)])
    assert e.value.code == 0
    out = capsys.readouterr().out
    assert "created group 'fuzzy'" in out
    add_calls = [c for c in fake.calls if c[:2] == ("group", "add")]
    assert add_calls == [("group", "add", "fuzzy", "--description=x")]
    assert not any(c[:2] == ("group", "del") for c in fake.calls)  # never deletes


def test_groups_check_mode_mutates_nothing(monkeypatch, tmp_path, capsys):
    fake = FakeSamba({("group", "list"): (0, "Waiter\n", "")})
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {"groups": [{"name": "newgrp"}]}
    with pytest.raises(SystemExit):
        apply_ad.main(["groups", "--check", "--plan", _plan_file(tmp_path, plan)])
    out = capsys.readouterr().out
    assert "WOULD-CHANGE" in out and "newgrp" in out
    assert not any(c[:2] == ("group", "add") for c in fake.calls)


def test_groups_nested_membership_additive(monkeypatch, tmp_path, capsys):
    # "E4E Admin" already exists; add it to "E4E Garage Admins" (not yet a member).
    fake = FakeSamba(
        {
            ("group", "list"): (0, "E4E Admin\nE4E Garage Admins\nDomain Admins\n", ""),
            ("group", "listmembers", "E4E Garage Admins"): (0, "someone\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {
        "groups": [
            {"name": "E4E Admin"},
            {"name": "E4E Garage Admins", "members": ["E4E Admin"]},
        ]
    }
    with pytest.raises(SystemExit) as e:
        apply_ad.main(["groups", "--plan", _plan_file(tmp_path, plan)])
    assert e.value.code == 0
    assert ("group", "addmembers", "E4E Garage Admins", "E4E Admin") in fake.calls


def test_groups_nested_membership_noop_when_member(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("group", "list"): (0, "E4E Admin\nDomain Admins\n", ""),
            ("group", "listmembers", "E4E Admin"): (0, "Domain Admins\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {"groups": [{"name": "E4E Admin", "members": ["Domain Admins"]}]}
    with pytest.raises(SystemExit):
        apply_ad.main(["groups", "--plan", _plan_file(tmp_path, plan)])
    assert not any(c[:2] == ("group", "addmembers") for c in fake.calls)
    assert "OK no-change" in capsys.readouterr().out


def test_groups_nested_membership_check_mode_mutates_nothing(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("group", "list"): (0, "E4E Admin\nE4E-NAS\n", ""),
            ("group", "listmembers", "E4E-NAS"): (0, "someone\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {"groups": [{"name": "E4E-NAS", "members": ["E4E Admin"]}]}
    with pytest.raises(SystemExit):
        apply_ad.main(["groups", "--check", "--plan", _plan_file(tmp_path, plan)])
    out = capsys.readouterr().out
    assert "WOULD-CHANGE" in out and "E4E Admin" in out
    assert not any(c[:2] == ("group", "addmembers") for c in fake.calls)


def test_service_account_absent_fails(monkeypatch, tmp_path, capsys):
    fake = FakeSamba({("user", "list"): (0, "Administrator\nsvc_roster\n", "")})
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {"accounts": [{"name": "authentik-bind", "member_of": []}]}
    with pytest.raises(SystemExit) as e:
        apply_ad.main(["service-accounts", "--plan", _plan_file(tmp_path, plan)])
    assert e.value.code == 2
    assert "ABSENT" in capsys.readouterr().out


def test_service_account_membership_additive(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("user", "list"): (0, "svc_roster\nauthentik-bind\n", ""),
            ("group", "listmembers", "Account Operators"): (0, "someoneelse\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {"accounts": [{"name": "svc_roster", "member_of": ["Account Operators"]}]}
    with pytest.raises(SystemExit) as e:
        apply_ad.main(["service-accounts", "--plan", _plan_file(tmp_path, plan)])
    assert e.value.code == 0
    assert ("group", "addmembers", "Account Operators", "svc_roster") in fake.calls


def test_service_account_membership_noop_when_member(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("user", "list"): (0, "svc_roster\n", ""),
            ("group", "listmembers", "Account Operators"): (0, "svc_roster\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {"accounts": [{"name": "svc_roster", "member_of": ["Account Operators"]}]}
    with pytest.raises(SystemExit):
        apply_ad.main(["service-accounts", "--plan", _plan_file(tmp_path, plan)])
    assert not any(c[:2] == ("group", "addmembers") for c in fake.calls)
    assert "OK no-change" in capsys.readouterr().out


def test_acls_grants_when_missing(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("user", "show", "authentik-bind"): (0, "objectSid: " + AUTHENTIK_SID + "\n", ""),
            ("dsacl", "get"): (0, "O:DAG:DAD:(A;;RPWP;;;DA)\n", ""),  # no reset ACE
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {
        "acls": [
            {
                "objectdn": "CN=Users,DC=krg,DC=local",
                "trustee": "authentik-bind",
                "right": "reset-password",
                "inherit": "child-users",
            }
        ]
    }
    with pytest.raises(SystemExit) as e:
        apply_ad.main(["acls", "--plan", _plan_file(tmp_path, plan)])
    assert e.value.code == 0
    set_calls = [c for c in fake.calls if c[:2] == ("dsacl", "set")]
    assert len(set_calls) == 1
    assert AUTHENTIK_SID in set_calls[0][-1] and RESET_GUID in set_calls[0][-1]


def test_acls_noop_when_present(monkeypatch, tmp_path, capsys):
    sddl = "D:(OA;CI;CR;{};;{})".format(RESET_GUID, AUTHENTIK_SID)
    fake = FakeSamba(
        {
            ("user", "show", "authentik-bind"): (0, "objectSid: " + AUTHENTIK_SID + "\n", ""),
            ("dsacl", "get"): (0, sddl + "\n", ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {
        "acls": [
            {
                "objectdn": "CN=Users,DC=krg,DC=local",
                "trustee": "authentik-bind",
                "right": "reset-password",
                "inherit": "child-users",
            }
        ]
    }
    with pytest.raises(SystemExit):
        apply_ad.main(["acls", "--plan", _plan_file(tmp_path, plan)])
    assert not any(c[:2] == ("dsacl", "set") for c in fake.calls)
    assert "OK no-change" in capsys.readouterr().out


def test_password_policy_sets_on_drift(monkeypatch, tmp_path, capsys):
    fake = FakeSamba(
        {
            ("domain", "passwordsettings", "show"): (0, LIVE_PWD_SHOW, ""),
        }
    )
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {
        "max_pwd_age": 0,
        "min_pwd_length": 12,
        "complexity": "on",
        "history_length": 24,
        "min_pwd_age": 1,
    }
    with pytest.raises(SystemExit) as e:
        apply_ad.main(["password-policy", "--plan", _plan_file(tmp_path, plan)])
    assert e.value.code == 0
    set_calls = [c for c in fake.calls if c[:3] == ("domain", "passwordsettings", "set")]
    assert len(set_calls) == 1
    flags = set_calls[0][3:]
    assert "--max-pwd-age=0" in flags and "--min-pwd-length=12" in flags


def test_password_policy_noop_when_converged(monkeypatch, tmp_path, capsys):
    converged = LIVE_PWD_SHOW.replace("length: 7", "length: 12").replace(
        "age (days): 42", "age (days): 0"
    )
    fake = FakeSamba({("domain", "passwordsettings", "show"): (0, converged, "")})
    monkeypatch.setattr(apply_ad, "run", fake)
    plan = {
        "max_pwd_age": 0,
        "min_pwd_length": 12,
        "complexity": "on",
        "history_length": 24,
        "min_pwd_age": 1,
    }
    with pytest.raises(SystemExit):
        apply_ad.main(["password-policy", "--plan", _plan_file(tmp_path, plan)])
    assert not any(c[:3] == ("domain", "passwordsettings", "set") for c in fake.calls)
    assert "converged" in capsys.readouterr().out
