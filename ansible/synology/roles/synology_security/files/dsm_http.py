"""DSM HTTP webapi client — the path the DSM web UI uses.

The `synowebapi --exec` CLI segfaults on `Firewall.Rules.save_start` with concrete
rule objects (DSM 7.2.2 bug; reproduced by the synoscgi backend crashing mid-
response → nginx 502). The DSM web UI bypasses this by using a different API
entirely (`Firewall.Profile.set` for the rule push, then
`Firewall.Profile.Apply.start` to commit) over the HTTP webapi.

This module is the stdlib-only client for that path. Used by apply_security.py
to push firewall profiles (and any other HTTP-only DSM API) from the
`script:`+`raw` pattern the other synology_* roles use.

Transport details (captured from the DSM 7.2.2 web UI's XHRs, 2026-05-31):
  - POST to https://localhost:6021/webapi/entry.cgi
  - Content-Type: application/x-www-form-urlencoded
  - JSON values in form fields are quoted/escaped per JSON (e.g. name="default"
    becomes `name=%22default%22`, NOT bare `name=default`).
  - X-SYNO-TOKEN header: required for state-changing calls; returned by the
    login response when `enable_syno_token=yes` is set.
  - X-SYNO-HASH header: OPTIONAL — the UI sends a per-request anti-replay hash,
    but the server only validates it IF PRESENT. Wrong value → err 119
    "session hash invalid"; omitted → call succeeds. We omit.
  - Session cookie via `format=cookie` on login.

Localhost-only by design: this runs on the NAS itself (Ansible `script:` /
`raw:` modules execute on the target), so SSL verification is skipped — the
cert is the DSM self-signed cert at https://localhost:6021 and the operator
can't realistically MITM their own loopback.
"""
import http.cookiejar
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request


class DSMError(Exception):
    """A DSM webapi call returned success=false or non-200 HTTP."""

    def __init__(self, msg, code=None, payload=None):
        super().__init__(msg)
        self.code = code
        self.payload = payload


class DSMSession(object):
    """HTTP webapi session — context-manage to ensure logout on exit."""

    def __init__(self, host="localhost", port=6021, account="e4e-admin",
                 password=None, timeout=30):
        if not password:
            raise ValueError("password is required")
        self.base = "https://%s:%d/webapi/entry.cgi" % (host, port)
        self.account = account
        self._password = password
        self.timeout = timeout
        self.token = None  # X-SYNO-TOKEN, populated by login()
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        cj = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(cj),
        )

    def __enter__(self):
        self.login()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            self.logout()
        except Exception:
            pass  # never mask the original exception

    def _post(self, params, raw_headers=None):
        """POST form-encoded; return parsed JSON or raise DSMError."""
        headers = {"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"}
        if self.token:
            headers["X-SYNO-TOKEN"] = self.token
        if raw_headers:
            headers.update(raw_headers)
        data = urllib.parse.urlencode(params).encode("utf-8")
        req = urllib.request.Request(self.base, data=data, headers=headers)
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as e:
            raise DSMError("HTTP %d on %s" % (e.code, params.get("api", "?")),
                           code=e.code, payload=e.read()[:300])
        try:
            return json.loads(body)
        except ValueError:
            raise DSMError("non-JSON response on %s" % params.get("api", "?"),
                           payload=body[:300])

    @staticmethod
    def _check(resp, what):
        if not resp.get("success"):
            err = resp.get("error", {})
            raise DSMError("%s failed (code=%s)" % (what, err.get("code")),
                           code=err.get("code"), payload=resp)
        return resp.get("data", {})

    def login(self):
        resp = self._post({
            "api": "SYNO.API.Auth", "version": "7", "method": "login",
            "account": self.account, "passwd": self._password,
            "session": "FileStation", "format": "cookie",
            "enable_syno_token": "yes",
        })
        data = self._check(resp, "login")
        self.token = data.get("synotoken")
        if not self.token:
            raise DSMError("login succeeded but no SynoToken returned",
                           payload=data)
        return data

    def logout(self):
        if not self.token:
            return
        try:
            self._post({"api": "SYNO.API.Auth", "version": "7", "method": "logout"})
        finally:
            self.token = None

    def call(self, api, method, version=1, **params):
        """Generic webapi call.

        Values are sent JSON-quoted per the UI convention: strings become
        \"string\" (e.g. name=\"default\"), booleans become true/false, ints
        stay ints, dicts/lists are JSON-stringified. Empty strings are sent as
        \"\". This matches what the UI puts on the wire and avoids the parser
        quirks we hit going through synowebapi --exec.
        """
        form = {"api": api, "method": method, "version": str(version)}
        for k, v in params.items():
            if isinstance(v, bool):
                form[k] = "true" if v else "false"
            elif isinstance(v, (int, float)):
                form[k] = str(v)
            elif isinstance(v, str):
                form[k] = json.dumps(v)  # JSON-quoted string
            else:
                form[k] = json.dumps(v, separators=(",", ":"))
        return self._post(form)

    # ---- Firewall.Profile helpers (set + Apply two-phase) -----------------

    def profile_get(self, name):
        return self._check(self.call(
            "SYNO.Core.Security.Firewall.Profile", "get", name=name,
        ), "Profile.get(%s)" % name)

    def profile_set(self, profile, applying=False):
        """Save a profile (write to /usr/syno/etc/firewall.d/*.json).

        `profile` is the full {name, <adapter>: {policy, rules}, ...} dict
        — the same shape Profile.get returns. `applying=False` saves without
        activating; use profile_apply() to commit.
        """
        # Profile.set wants the full profile JSON as one form field.
        form = {
            "api": "SYNO.Core.Security.Firewall.Profile",
            "method": "set",
            "version": "1",
            "profile": json.dumps(profile, separators=(",", ":")),
            "profile_applying": "true" if applying else "false",
        }
        return self._check(self._post(form), "Profile.set")

    def profile_apply(self, name, poll_interval=0.5, timeout=60):
        """Commit a saved profile to live nftables (Profile.Apply two-phase).

        Returns when the apply task reports finish=true, or raises on
        timeout. Always calls Apply.stop in a finally block to free the task
        slot (matches the UI: stop is unconditional after status, not after
        start failure).

        `profile_applying=False` matches the UI's call (`True` errors 117 on
        DSM 7.2.2). The flag is a context hint, not a "do it" toggle — the
        actual commit happens regardless.
        """
        import time
        started = self._check(self.call(
            "SYNO.Core.Security.Firewall.Profile.Apply", "start",
            name=name, profile_applying=False,
        ), "Profile.Apply.start")
        task_id = started.get("task_id")
        if not task_id:
            raise DSMError("Profile.Apply.start returned no task_id",
                           payload=started)
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                status = self._check(self.call(
                    "SYNO.Core.Security.Firewall.Profile.Apply", "status",
                    task_id=task_id,
                ), "Profile.Apply.status")
                if status.get("finish"):
                    return status
                time.sleep(poll_interval)
            raise DSMError("Profile.Apply timed out after %ds (task=%s)"
                           % (timeout, task_id))
        finally:
            try:
                self.call("SYNO.Core.Security.Firewall.Profile.Apply", "stop")
            except DSMError:
                pass
