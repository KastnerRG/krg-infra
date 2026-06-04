"""Unit tests for apply_quotas.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_quotas as m  # noqa: E402


class _R:
    def __init__(self, stdout="", rc=0):
        self.stdout = stdout
        self.returncode = rc
        self.stderr = ""


# --- _parse_current ---------------------------------------------------------
# M3 (reviewer 4577021512): DSM displays decimal GB; the setter writes binary
# GiB. The parser must convert so equal-intent values compare equal.
#
#   500 GiB  ==  500 * 2^30 bytes  ≈  537 GB (decimal)
#   500 GB   ==  500 * 10^9 bytes  ≈  465 GiB (binary)
#
# So a setter that wrote 500 GiB and a reader that sees "Quota: 537 GB"
# should both reduce to 500 GiB on comparison.
def test_parse_current_gib_unchanged():
    assert m._parse_current("Quota: 500 GiB") == (500, False)
    assert m._parse_current("Quota: 500 GiB (Hard)") == (500, True)


def test_parse_current_decimal_gb_converts_to_gib():
    # 537 GB ≈ 500 GiB (round-trip from a 500-GiB setter write)
    assert m._parse_current("Quota: 537 GB (Hard)") == (500, True)


def test_parse_current_decimal_tb_converts_to_gib():
    # 2 TB = 2 * 10^12 bytes = 1862.65 GiB → rounds to 1863
    assert m._parse_current("Quota: 2 TB (Soft)") == (1863, False)


def test_parse_current_binary_tib():
    # 2 TiB = 2048 GiB exactly
    assert m._parse_current("Quota: 2 TiB") == (2048, False)


def test_parse_current_no_quota_or_unparseable():
    assert m._parse_current("No quota set") == (None, None)
    assert m._parse_current("???")[0] == "UNPARSEABLE"


# --- share quota -----------------------------------------------------------
def test_share_no_change_after_decimal_gb_round_trip(monkeypatch, capsys):
    """Regression: setter wrote 500 GiB earlier; DSM now displays it as 537 GB.
    Without the M3 fix, this would forever report CHANGED."""
    monkeypatch.setattr(m, "_run", lambda cmd: _R("Quota: 537 GB (Hard)"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_no_change_gib_display(monkeypatch, capsys):
    """DSM that displays GiB directly — also OK no-change."""
    monkeypatch.setattr(m, "_run", lambda cmd: _R("Quota: 500 GiB (Hard)"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_drift_applies_set(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get-share" in cmd:
            return _R("Quota: 200 GB (Soft)")    # drift on both size + hard
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(c for c in calls if "--set-share" in c)
    assert "temp" in set_call
    assert "--size" in set_call
    assert str(500 * (1 << 30)) in set_call
    assert "hard" in set_call


def test_share_clear_when_size_zero(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get-share" in cmd:
            return _R("Quota: 500 GB (Hard)")
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["share", "--share", "temp", "--size-gib", "0", "--hard", "false"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    assert any("--clear-share" in c for c in calls)


def test_share_size_zero_no_existing_quota_is_noop(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R("No quota set"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "0", "--hard", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_check_mode(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _R("Quota: 200 GB (Hard)")

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true", "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    # only the get was issued — no set
    assert not any("--set-share" in c for c in calls)


def test_share_unparseable_fails(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _R("???"))
    rc = m.main(["share", "--share", "temp", "--size-gib", "500", "--hard", "true"])
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")


# --- user quota ------------------------------------------------------------
def test_user_drift_applies_set(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get" in cmd and "--user" in cmd:
            return _R("Quota: 100 GB (Soft)")
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main([
        "user", "--user", "alice", "--volume", "/volume1",
        "--size-gib", "200", "--hard", "false",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    set_call = next(c for c in calls if "--set" in c and "--user" in c)
    assert "alice" in set_call and "/volume1" in set_call


def test_user_hard_change_only(monkeypatch, capsys):
    """size unchanged but hard flips soft->hard -> drift."""
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        if "--get" in cmd and "--user" in cmd:
            return _R("Quota: 200 GB (Soft)")
        return _R("", 0)

    monkeypatch.setattr(m, "_run", fake_run)
    rc = m.main([
        "user", "--user", "alice", "--volume", "/volume1",
        "--size-gib", "200", "--hard", "true",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
