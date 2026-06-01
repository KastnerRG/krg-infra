"""Unit tests for apply_notifications.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_notifications as m  # noqa: E402


def _factory(routes):
    """routes: dict mapping API → dict of GET data; set calls captured into `captured`."""
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(routes[api]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_mail_no_change(monkeypatch, capsys):
    fake, _ = _factory({
        "SYNO.Core.Notification.Mail.Conf": {
            "enable_mail": True, "enable_oauth": True, "sender_mail": "x@y", "sender_name": "",
            "subject_prefix": "[e4e]",
            "smtp_info": {"server": "smtp.gmail.com", "port": 465, "ssl": True, "verifyCert": False},
            "smtp_auth": {"user": "x@y", "enable": True},
        }
    })
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["mail", "--enable", "true", "--oauth", "true",
                 "--sender-mail", "x@y", "--sender-name", "",
                 "--subject-prefix", "[e4e]",
                 "--smtp-server", "smtp.gmail.com", "--smtp-port", "465", "--smtp-ssl", "true",
                 "--auth-user", "x@y"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_mail_apply_preserves_nested(monkeypatch, capsys):
    live = {
        "enable_mail": False, "enable_oauth": True, "sender_mail": "old@x",
        "smtp_info": {"server": "old.smtp", "port": 25, "ssl": False, "verifyCert": False},
        "smtp_auth": {"user": "old", "enable": True},
    }
    fake, captured = _factory({"SYNO.Core.Notification.Mail.Conf": live})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["mail", "--enable", "true",
                 "--sender-mail", "new@y",
                 "--smtp-server", "smtp.gmail.com", "--smtp-port", "465", "--smtp-ssl", "true",
                 "--auth-user", "new@y"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    # the smtp_info JSON contains the OVERLAID server+port+ssl and the PRESERVED verifyCert
    smtp_info = next(x for x in rest if x.startswith("smtp_info="))
    assert '"server": "smtp.gmail.com"' in smtp_info and '"verifyCert": false' in smtp_info


def test_sms_apply(monkeypatch, capsys):
    """DSM's SMS.Conf field is `enable_sms`, not `enable` — script
    translates the CLI's bare --enable to that field name (fixed
    2026-05-31; was producing false-positive CHANGED every run because
    current.get('enable') was None vs desired=false)."""
    fake, captured = _factory({"SYNO.Core.Notification.SMS.Conf": {"enable_sms": True}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["sms", "--enable", "false"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    set_args = next(p for a, p in [captured[0]] if "method=set" in p)
    assert "enable_sms=false" in set_args


def test_push_check(monkeypatch, capsys):
    fake, _ = _factory({"SYNO.Core.Notification.Push.Conf": {
        "msn_enable": True, "skype_enable": False, "mobile_enable": False}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["push", "--msn", "false", "--skype", "false", "--mobile", "false", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "msn_enable" in out


def test_cms_no_change(monkeypatch, capsys):
    """DSM's CMS.Conf field is `cms_enable`, not `enable` — same fix
    pattern as SMS above."""
    fake, _ = _factory({"SYNO.Core.Notification.CMS.Conf": {"cms_enable": False}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["cms", "--enable", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
