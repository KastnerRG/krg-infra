"""Unit tests for apply_acls.py — run with: pytest (no DSM needed).

parse_list_acl is tested against the EXACT `synoshare --list_acl` output captured from
the DSM 7.3 rig. The subprocess boundary `_run` is monkeypatched to drive the
OK/WOULD-CHANGE/CHANGED/FAIL contract and verify only drifted tiers are re-set.
"""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import apply_acls as m  # noqa: E402

# Verbatim rig output (note the leading tabs and variable dot-runs).
RIG_LIST_ACL = (
    "SYNOSHARE ACL Perm List:\n"
    "\t Name ............[acltest]\n"
    "\t ACL RO List .....[myadmin]\n"
    "\t ACL RW List .....[@rigtest,bob]\n"
    "\t ACL NA List .....[]\n"
    "\t ACL Custom List .[]\n"
)


class _R:
    def __init__(self, stdout="", rc=0):
        self.stdout = stdout
        self.returncode = rc
        self.stderr = ""


# --- helpers (unchanged) -----------------------------------------------------
def test_parse_list_acl_real_output():
    t = m.parse_list_acl(RIG_LIST_ACL)
    assert t["RO"] == {"myadmin"}
    assert t["RW"] == {"@rigtest", "bob"}
    assert t["NA"] == set()


def test_desired_tiers_prefixes_groups():
    d = m.desired_tiers([{"group": "maya", "access": "rw"},
                         {"user": "alice", "access": "ro"},
                         {"group": "x", "access": "no"}])
    assert d["RW"] == {"@maya"} and d["RO"] == {"alice"} and d["NA"] == {"@x"}


def test_desired_tiers_rejects_bad_input():
    with pytest.raises(SystemExit):
        m.desired_tiers([{"group": "x", "access": "bogus"}])
    with pytest.raises(SystemExit):
        m.desired_tiers([{"access": "rw"}])


# --- setuser subcommand ------------------------------------------------------
def test_setuser_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R(RIG_LIST_ACL))
    grants = [{"user": "myadmin", "access": "ro"},
              {"group": "rigtest", "access": "rw"},
              {"user": "bob", "access": "rw"}]
    rc = m.main(["setuser", "--share", "acltest", "--grants", json.dumps(grants)])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_setuser_apply_only_resets_drifted_tiers(monkeypatch, capsys):
    setcalls = []

    def fake_run(cmd):
        # cmd is e.g. [SYNOSHARE, "--list_acl", "acltest"] or [SYNOSHARE, "--setuser", ...]
        if "--list_acl" in cmd:
            return _R(RIG_LIST_ACL)
        setcalls.append(cmd)
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["setuser", "--share", "acltest", "--grants",
                 json.dumps([{"group": "rigtest", "access": "rw"}])])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    tiers = {c[c.index("--setuser") + 2] for c in setcalls}
    assert tiers == {"RW", "RO"}   # NA was already empty -> not touched
    rw_csv = next(c[-1] for c in setcalls if c[c.index("--setuser") + 2] == "RW")
    ro_csv = next(c[-1] for c in setcalls if c[c.index("--setuser") + 2] == "RO")
    assert rw_csv == "@rigtest" and ro_csv == ""


def test_setuser_check_reports_without_setting(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R(RIG_LIST_ACL) if "--list_acl" in cmd
                        else (_ for _ in ()).throw(AssertionError("must not set in --check")))
    rc = m.main(["setuser", "--share", "acltest", "--grants",
                 json.dumps([{"group": "rigtest", "access": "rw"}]), "--check"])
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE")


def test_setuser_fail_when_errors(monkeypatch, capsys):
    def fake_run(cmd):
        return _R(RIG_LIST_ACL) if "--list_acl" in cmd else _R("denied", 1)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["setuser", "--share", "acltest", "--grants",
                 json.dumps([{"group": "rigtest", "access": "rw"}])])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


# --- admin-grants subcommand ------------------------------------------------
def _list_acl_with_rw(rw_list):
    """Build a synthetic --list_acl stdout with a custom RW list."""
    return (
        "SYNOSHARE ACL Perm List:\n"
        "\t Name ............[any]\n"
        "\t ACL RO List .....[]\n"
        "\t ACL RW List .....[" + ",".join(rw_list) + "]\n"
        "\t ACL NA List .....[]\n"
        "\t ACL Custom List .[]\n"
    )


def test_admin_grants_no_change_when_already_present(monkeypatch, capsys):
    """Every share already has all desired admin grants → OK no-change, NO setuser calls."""
    monkeypatch.setattr(m, "_run", lambda cmd:
                        _R(_list_acl_with_rw(["@administrators", "@KRG\\Domain Admins"])) if "--list_acl" in cmd
                        else (_ for _ in ()).throw(AssertionError("no-change must not invoke --setuser")))
    rc = m.main(["admin-grants",
                 "--shares", json.dumps(["admin", "maya"]),
                 "--grants", json.dumps(["@KRG\\Domain Admins"]),
                 "--tier", "RW"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_admin_grants_additive_only_for_missing(monkeypatch, capsys):
    """One share already has the grant, another doesn't — only the missing share gets --setuser +."""
    # admin already has the grant; maya doesn't.
    rw_by_share = {
        "admin": ["@administrators", "@KRG\\Domain Admins"],   # converged
        "maya":  ["@administrators"],                            # needs add
    }
    calls = []

    def fake_run(cmd):
        if "--list_acl" in cmd:
            share = cmd[cmd.index("--list_acl") + 1]
            return _R(_list_acl_with_rw(rw_by_share[share]))
        calls.append(cmd)
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["admin-grants",
                 "--shares", json.dumps(["admin", "maya"]),
                 "--grants", json.dumps(["@KRG\\Domain Admins"]),
                 "--tier", "RW"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    # Exactly ONE setuser call, on `maya`, with the `+` operator
    assert len(calls) == 1
    cmd = calls[0]
    assert cmd[cmd.index("--setuser") + 1] == "maya"
    assert cmd[cmd.index("--setuser") + 2] == "RW"
    assert cmd[cmd.index("--setuser") + 3] == "+"
    # Trailing CSV should only contain the missing entry (no duplicates, no clobber of @administrators)
    csv = cmd[cmd.index("--setuser") + 4]
    assert csv == "@KRG\\Domain Admins", (
        "must only `+`-add MISSING grants; instead added " + csv)


def test_admin_grants_check_mode_writes_nothing(monkeypatch, capsys):
    """--check reports drift but never invokes --setuser."""
    monkeypatch.setattr(m, "_run", lambda cmd:
                        _R(_list_acl_with_rw(["@administrators"])) if "--list_acl" in cmd
                        else (_ for _ in ()).throw(AssertionError("must not --setuser in check mode")))
    rc = m.main(["admin-grants",
                 "--shares", json.dumps(["admin"]),
                 "--grants", json.dumps(["@KRG\\Domain Admins", "@KRG\\E4E Admin"]),
                 "--tier", "RW", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    # both missing entries appear in the drift summary
    assert "Domain Admins" in out and "E4E Admin" in out


def test_admin_grants_never_touches_other_tiers(monkeypatch, capsys):
    """The role-contract guarantee: admin-grants only touches --tier; RO/NA stay intact."""
    calls = []

    def fake_run(cmd):
        if "--list_acl" in cmd:
            return _R(_list_acl_with_rw(["@administrators"]))
        calls.append(cmd)
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    m.main(["admin-grants",
            "--shares", json.dumps(["admin"]),
            "--grants", json.dumps(["@KRG\\Domain Admins"]),
            "--tier", "RW"])
    capsys.readouterr()
    # No call may target RO or NA tiers — the bug we're guarding against is a future
    # rewrite that flips synoshare to `=` semantics and wipes other tiers.
    for cmd in calls:
        tier_pos = cmd.index("--setuser") + 2
        assert cmd[tier_pos] == "RW", (
            "admin-grants must only touch --tier; saw " + cmd[tier_pos])


def test_admin_grants_rejects_bad_tier():
    """argparse choices= rejects a bogus tier — guard against future drift to
    a free-text --tier that could silently target an unintended ACL list."""
    with pytest.raises(SystemExit):
        m.main(["admin-grants",
                "--shares", "[]", "--grants", "[]", "--tier", "BOGUS"])


def test_admin_grants_propagates_setuser_failure(monkeypatch, capsys):
    """A --setuser failure on one share aborts the run with FAIL (no partial pretend success)."""
    def fake_run(cmd):
        if "--list_acl" in cmd:
            return _R(_list_acl_with_rw(["@administrators"]))
        return _R("permission denied", 1)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["admin-grants",
                 "--shares", json.dumps(["admin"]),
                 "--grants", json.dumps(["@KRG\\Domain Admins"]),
                 "--tier", "RW"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


# --- recursive-stamp subcommand ---------------------------------------------
def test_recursive_stamp_check_mode(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(m, "_run", lambda cmd: (_ for _ in ()).throw(
        AssertionError("must not invoke synoacltool in --check")))
    rc = m.main(["recursive-stamp", "--share", "maya", "--path", str(tmp_path), "--check"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("WOULD-CHANGE")
    assert "synoacltool" in out


def test_recursive_stamp_invokes_synoacltool(monkeypatch, capsys, tmp_path):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["recursive-stamp", "--share", "maya", "--path", str(tmp_path)])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    # exactly one synoacltool -reset -R call, with the right path
    assert len(calls) == 1
    assert calls[0][1:] == ["-reset", "-R", str(tmp_path)]


def test_recursive_stamp_rejects_missing_path(capsys):
    rc = m.main(["recursive-stamp", "--share", "maya", "--path", "/no/such/path"])
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "not a directory" in out


def test_recursive_stamp_failure_reports(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(m, "_run", lambda cmd: _R("permission denied", 1))
    rc = m.main(["recursive-stamp", "--share", "maya", "--path", str(tmp_path)])
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")
