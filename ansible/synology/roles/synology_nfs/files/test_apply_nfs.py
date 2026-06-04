"""Unit tests for apply_nfs.py — run with: pytest (no DSM needed).

The subprocess boundary is `_exec` (synowebapi); we monkeypatch it to return canned
GET/load responses and capture set/save calls, then assert the OK/WOULD-CHANGE/CHANGED
contract and the pure helpers.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_nfs as m  # noqa: E402

RULE = {"client": "10.0.0.5", "privilege": "rw", "root_squash": "root",
        "async": False, "insecure": False, "crossmnt": True,
        "security_flavor": {"sys": True, "kerberos": False,
                            "kerberos_integrity": False, "kerberos_privacy": False}}


def test_bool():
    assert m._bool("true") and m._bool("YES") and not m._bool("0")


def test_args_from_types():
    args = m._args_from({"a": True, "b": False, "n": None, "i": 3,
                         "lst": [1, 2], "obj": {"x": True}})
    assert "a=true" in args and "b=false" in args and "i=3" in args
    assert not any(x.startswith("n=") for x in args)            # null dropped
    assert "lst=[1, 2]" in args                                 # list -> json
    assert any(x.startswith("obj=") and '"x"' in x for x in args)  # dict -> json


def test_norm_order_insensitive():
    assert m._norm([{"client": "b"}, {"client": "a"}]) == m._norm([{"client": "a"}, {"client": "b"}])


# --- global ---------------------------------------------------------------------
def test_global_no_change(monkeypatch, capsys):
    def fake(api, *p):
        assert "method=set" not in p, "must not set"
        return {"data": {"enable_nfs": True, "enable_nfs_v4": True, "nfs_v4_domain": ""}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["global", "--enable", "true", "--nfsv4", "true", "--v4-domain", ""])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_global_apply_sends_full_object(monkeypatch, capsys):
    calls = []

    def fake(api, *p):
        if "method=get" in p:
            return {"data": {"enable_nfs": False, "enable_nfs_v4": False,
                             "nfs_v4_domain": "", "read_size": 8192}}
        calls.append(p)
        return {"success": True}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["global", "--enable", "true", "--nfsv4", "true"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    setp = calls[0]
    assert "method=set" in setp
    assert "enable_nfs=true" in setp and "enable_nfs_v4=true" in setp
    assert "read_size=8192" in setp  # untouched field retained (full object)


# --- share-rules ----------------------------------------------------------------
def test_share_rules_no_change(monkeypatch, capsys):
    def fake(api, *p):
        assert "method=save" not in p, "must not save"
        return {"data": {"rule": [dict(RULE)]}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["share-rules", "--share", "x", "--rules", json.dumps([RULE])])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_rules_apply(monkeypatch, capsys):
    saved = {}

    def fake(api, *p):
        if "method=load" in p:
            return {"data": {"rule": []}}
        saved["p"] = p
        return {"success": True}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["share-rules", "--share", "myshare", "--rules", json.dumps([RULE])])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    assert "method=save" in saved["p"] and "share_name=myshare" in saved["p"]
    assert any(x.startswith("rule=") for x in saved["p"])


def test_share_rules_fail(monkeypatch, capsys):
    def fake(api, *p):
        if "method=load" in p:
            return {"data": {"rule": []}}
        return {"success": False, "error": {"code": 2301}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["share-rules", "--share", "x", "--rules", json.dumps([RULE])])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")
