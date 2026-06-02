"""Unit tests for apply_dsm_system.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_dsm_system as m  # noqa: E402


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


def test_network_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({
        "server_name": "e4e-nas", "gateway": "132.239.17.1",
        "dns_primary": "132.239.95.109", "dns_secondary": "1.1.1.1",
        "dns_manual": True, "ipv4_first": False,
    }))
    rc = m.main(["network", "--hostname", "e4e-nas",
                 "--gateway", "132.239.17.1",
                 "--dns-primary", "132.239.95.109",
                 "--dns-secondary", "1.1.1.1",
                 "--dns-manual", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_network_apply_hostname_drift(monkeypatch, capsys):
    """SET payload uses JSON-quoted string values (validated 2026-06-01:
    synowebapi --exec parses each key=value as JSON; bare `132.239.17.1`
    became float `132.239` and DSM rejected with err 4302). Asserts
    JSON-quoted form `server_name="e4e-nas"` not bare `server_name=e4e-nas`."""
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"server_name": "e4e_nas", "gateway": "132.239.17.1",
         "dns_primary": "132.239.95.109", "extra_unmanaged": "stays"},
        set_capture=captured))
    rc = m.main(["network", "--hostname", "e4e-nas"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    api, params = captured[0]
    assert api == "SYNO.Core.Network" and "version=2" in params
    rest = set(params[2:])
    assert 'server_name="e4e-nas"' in rest                # JSON-quoted string
    assert 'extra_unmanaged="stays"' in rest              # unmanaged preserved + JSON-quoted
    assert 'gateway="132.239.17.1"' in rest               # unmanaged preserved + JSON-quoted


def test_network_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"server_name": "e4e_nas"}))
    rc = m.main(["network", "--hostname", "e4e-nas", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "server_name" in out


def test_network_fail(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {"server_name": "x"}, "success": True}
        return {"success": False, "error": {"code": 2001}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["network", "--hostname", "y"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")
