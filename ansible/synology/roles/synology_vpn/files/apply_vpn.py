#!/usr/bin/env python3
"""Apply DSM VPN Server (OpenVPN) config idempotently from spec/e4e-nas/vpn.yml.

Invoked by the synology_vpn ansible role via `script` (DSM ships py3.8, below
ansible's module floor — see [[synology-script-raw-pattern]]).

Subcommands:

  package     ensure the VPNCenter package is RUNNING (synopkg). Must run first:
              DSM leaves VPN Server stopped after install, and while it is
              stopped its webapi libs are NOT registered, so every
              SYNO.VPNServer.* call returns err 102. Confirmed on e4e-nas
              2026-08-16.
  openvpn     SYNO.VPNServer.Settings.Config   load -> overlay -> apply
  privilege   SYNO.VPNServer.Management.Account load -> overlay -> apply
  publish     render the client .ovpn and drop it in a share (default:
              /volume1/installers) so users can self-serve it

NOTE THE VERBS. This package uses load/apply, NOT the get/set every other
synology_* role wraps. `load` returns the current object; `apply` takes the
full object back (partial = rejected, same full-object rule as the Core APIs).

⚠️ FIELD NAMES ARE UNCONFIRMED. Settings.Config's schema could not be read
before this role existed (chicken-and-egg: the package must run for the API to
register, and nothing started it). OUT_KEYS below is the best-known mapping;
the role's export.yml dumps the live `load` payload on first run — flip
OUT_KEYS to match and the guesswork is over. Same OUT_KEYS-flip pattern as
apply_ad.py / apply_external_access.py.

What the SHIPPED openvpn.conf actually contains (read off e4e-nas 2026-08-16,
before any config) — these are the drift items this subcommand exists to fix:
    server 10.8.0.0 255.255.255.0     -> spec subnet (10.90.24.0/24)
    max-clients 5                     -> spec max_connections
    comp-lzo                          -> MUST go (VORACLE, CVE-2018-9336 class)
    duplicate-cn                      -> kept (see spec: laptop + phone)
    proto udp6                        -> dual-stack listener
    plugin radiusplugin.so            -> the auth path (NOT pam)
    verify-client-cert none           -> username/password only, no client certs
    username-as-common-name
"""

import argparse
import http.cookiejar
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

WEBAPI = "/usr/syno/bin/synowebapi"
SYNOPKG = "/usr/syno/bin/synopkg"
PKG = "VPNCenter"

CONFIG_API = "SYNO.VPNServer.Settings.Config"
ACCOUNT_API = "SYNO.VPNServer.Management.Account"

# DSM error codes
ERR_API_NOT_EXIST = 102

# Where DSM keeps the material the client config needs. Both files are created
# by the package's postinst (ta.key via `openvpn --genkey`), so they exist as
# soon as the package is installed — no need to wait for it to be configured.
KEYS_DIR = "/usr/syno/etc/packages/VPNCenter/openvpn/keys"
CA_CRT = os.path.join(KEYS_DIR, "ca.crt")
TA_KEY = os.path.join(KEYS_DIR, "ta.key")

# ⚠️ BEST-KNOWN Settings.Config field names — flip on first `--tags export`.
OUT_KEYS = {
    "enabled": "enable_openvpn",
    "port": "ovpn_port",
    "protocol": "ovpn_protocol",
    "subnet": "ovpn_dynamic_ip",
    "netmask": "ovpn_netmask",
    "max_connections": "ovpn_max_conn",
    "allow_lan": "ovpn_client_access_server_lan",
    "push_dns": "ovpn_push_dns",
    "ipv6": "ovpn_enable_ipv6",
    "cipher": "ovpn_cipher",
    "auth_digest": "ovpn_auth",
    "compression": "ovpn_compress",
    "tls_auth": "ovpn_tls_auth",
    "duplicate_cn": "ovpn_duplicate_cn",
}


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


# ---- HTTP webapi client (inlined; mirrors apply_security.py) ------------------
# WHY HTTP AND NOT `synowebapi --exec`. With the package RUNNING, the CLI runner
# returns err 600 on SYNO.VPNServer.Settings.Config load — with and without a
# `type` param (measured on e4e-nas, DSM 7.3.2, 2026-08-16). That is the same
# wall synology_security hit on Firewall.Profile: these are UI-driven APIs that
# want an authenticated web session, not the SYSTEM_ADMIN CLI runner. So we do
# what the DSM web UI does.
#
# INLINED ON PURPOSE. Ansible's `script:` module ships only the named file to
# the target, so `from dsm_http import ...` fails with ModuleNotFoundError at
# run time. apply_security.py carries the same duplicated client for the same
# reason (it was a shared dsm_http.py until 2026-05-31). Keep them in sync by
# hand; do not "DRY" this into an import.


class DSMError(Exception):
    """A DSM webapi call returned success=false or non-200 HTTP."""

    def __init__(self, msg, code=None, payload=None):
        super().__init__(msg)
        self.code = code
        self.payload = payload


class DSMSession(object):
    """HTTP webapi session — context-manage to ensure logout on exit."""

    def __init__(self, host="localhost", port=6021, account="e4e-admin", password=None, timeout=30):
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

    def _post(self, params):
        headers = {"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"}
        if self.token:
            headers["X-SYNO-TOKEN"] = self.token
        data = urllib.parse.urlencode(params).encode("utf-8")
        req = urllib.request.Request(self.base, data=data, headers=headers)
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as e:
            raise DSMError(
                "HTTP %d on %s" % (e.code, params.get("api", "?")),
                code=e.code,
                payload=e.read()[:300],
            )
        try:
            return json.loads(body)
        except ValueError:
            raise DSMError("non-JSON response on %s" % params.get("api", "?"), payload=body[:300])

    def login(self):
        resp = self._post(
            {
                "api": "SYNO.API.Auth",
                "version": "7",
                "method": "login",
                "account": self.account,
                "passwd": self._password,
                "session": "FileStation",
                "format": "cookie",
                "enable_syno_token": "yes",
            }
        )
        if not resp.get("success"):
            err = resp.get("error", {}) or {}
            raise DSMError("login failed (code=%s)" % err.get("code"), code=err.get("code"))
        self.token = (resp.get("data") or {}).get("synotoken")
        if not self.token:
            raise DSMError("login succeeded but no SynoToken returned")
        return resp

    def logout(self):
        if not self.token:
            return
        try:
            self._post({"api": "SYNO.API.Auth", "version": "7", "method": "logout"})
        finally:
            self.token = None

    def call(self, api, method, version=1, **params):
        """Generic webapi call. String params get JSON-quoted (UI convention)."""
        form = {"api": api, "method": method, "version": str(version)}
        for k, v in params.items():
            if isinstance(v, bool):
                form[k] = "true" if v else "false"
            elif isinstance(v, (int, float)):
                form[k] = str(v)
            elif isinstance(v, str):
                form[k] = json.dumps(v)
            else:
                form[k] = json.dumps(v, separators=(",", ":"))
        return self._post(form)


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _session(a):
    pw = a.password or os.environ.get("DSM_PASSWORD") or ""
    if not pw:
        raise DSMError(
            "no DSM password supplied — pass --password or set DSM_PASSWORD. "
            "The VPNServer APIs need a web session; the CLI runner returns "
            "err 600 on Settings.Config.load."
        )
    return DSMSession(account=a.account, password=pw)


def _load(sess, api):
    """`load` the current object. Returns (data, None) or (None, err_code)."""
    resp = sess.call(api, "load")
    if not resp.get("success", False):
        return None, (resp.get("error") or {}).get("code")
    if "data" not in resp:
        raise DSMError("%s load: success but no data: %s" % (api, json.dumps(resp)))
    return resp["data"], None


def _apply(sess, api, obj):
    resp = sess.call(api, "apply", **obj)
    if not resp.get("success", False):
        raise DSMError("%s apply failed: %s" % (api, json.dumps(resp.get("error"))))
    return resp


# --- package ------------------------------------------------------------------
def cmd_package(a):
    """Ensure VPNCenter is installed AND running.

    Installation itself is terraform's job (terraform/e4e-nas/packages.tf); this
    only starts it. Reported separately from the config subcommands because a
    stopped package makes every later call fail with a misleading err 102.
    """
    st = _run([SYNOPKG, "status", PKG])
    # synopkg's EXIT CODE is not an install check. Measured on DSM 7.3.2:
    #   installed but stopped -> rc 17
    #   not installed         -> rc 255, and aspect.error.status == "non_installed"
    # Both print JSON. Keying off `rc != 0` reported a merely-stopped package as
    # uninstalled — which is the exact state this subcommand exists to fix, so
    # the role could never start anything. Caught on the rig 2026-08-16.
    try:
        data = json.loads(st.stdout[st.stdout.find("{") :])
    except (ValueError, IndexError):
        print(
            "FAIL could not parse synopkg status (rc=%s): %s"
            % (st.returncode, (st.stdout or st.stderr).strip()[:200])
        )
        return 1

    err = (data.get("aspect") or {}).get("error") or data.get("error") or {}
    if err.get("status") == "non_installed":
        print("FAIL %s is not installed — terraform/e4e-nas owns the install" % PKG)
        return 1

    status = data.get("status")
    if status is None:
        print("FAIL synopkg status returned no `status`: %s" % json.dumps(data)[:200])
        return 1

    if status == "start":
        print("OK no-change package running")
        return 0
    if a.check:
        print("WOULD-CHANGE package status=%s -> start" % status)
        return 0

    out = _run([SYNOPKG, "start", PKG])
    if out.returncode != 0:
        print("FAIL could not start %s: %s" % (PKG, (out.stderr or out.stdout).strip()[:200]))
        return 1
    print("CHANGED package started (was %s)" % status)
    return 0


# --- openvpn ------------------------------------------------------------------
def cmd_openvpn(a):
    desired_spec = {
        "enabled": _bool(a.enable),
        "port": int(a.port),
        "protocol": a.protocol,
        "subnet": a.subnet,
        "netmask": a.netmask,
        "max_connections": int(a.max_connections),
        "allow_lan": _bool(a.allow_lan),
        "push_dns": _bool(a.push_dns),
        "ipv6": _bool(a.ipv6),
        "cipher": a.cipher,
        "auth_digest": a.auth_digest,
        "compression": _bool(a.compression),
        "tls_auth": _bool(a.tls_auth),
        "duplicate_cn": _bool(a.duplicate_cn),
    }

    # Refuse to push a config that would turn the NAS into a router onto the
    # campus network. This is the ONE setting whose failure mode is a security
    # incident rather than a broken service, so it is enforced here as well as
    # documented in the spec — a typo in vpn.yml should not be able to do it.
    if desired_spec["allow_lan"]:
        print(
            "FAIL refusing allow_lan=true: it makes DSM enable ip_forward + "
            "MASQUERADE and push a LAN route, turning e4e-nas into a gateway "
            "onto the flat-public campus subnet. See spec/e4e-nas/vpn.yml."
        )
        return 1

    with _session(a) as sess:
        return _openvpn_within(a, sess, desired_spec)


def _openvpn_within(a, sess, desired_spec):
    current, err = _load(sess, CONFIG_API)
    if err == ERR_API_NOT_EXIST:
        print(
            "FAIL %s returned err 102 — the VPNCenter package is almost "
            "certainly stopped (its webapi only registers while running). Run "
            "the `package` subcommand first." % CONFIG_API
        )
        return 1
    if err is not None:
        print("FAIL %s load failed with err %s" % (CONFIG_API, err))
        return 1

    desired = {OUT_KEYS[k]: v for k, v in desired_spec.items()}
    unknown = [k for k in desired if k not in current]
    if unknown:
        # Loud, not silent: a stale OUT_KEYS mapping would otherwise "succeed"
        # while configuring nothing, and the operator would find a wide-open or
        # unconfigured VPN. Dump the real keys so the fix is mechanical.
        print(
            "FAIL OUT_KEYS mismatch — %s not present in the live object. "
            "Live keys: %s" % (sorted(unknown), sorted(current.keys()))
        )
        return 1

    drift = {k: (current.get(k), v) for k, v in desired.items() if current.get(k) != v}
    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(sorted(drift.keys())))
        return 0

    target = dict(current)
    target.update(desired)
    _apply(sess, CONFIG_API, target)
    print("CHANGED " + json.dumps(sorted(drift.keys())))
    return 0


# --- privilege ----------------------------------------------------------------
def cmd_privilege(a):
    """Grant VPN access to the AD groups named in the spec.

    Deliberately group-scoped, never `everyone`: an everyone-grant would include
    the LOCAL accounts (e4e-admin break-glass, e4e-automation), handing two
    administrators-group accounts a password-authenticated internet front door
    and undoing the point of key-only SSH.
    """
    groups = json.loads(a.groups) if a.groups else []
    if not isinstance(groups, list) or not groups:
        print("FAIL --groups must be a non-empty JSON list")
        return 1

    with _session(a) as sess:
        return _privilege_within(a, sess, groups)


def _privilege_within(a, sess, groups):
    current, err = _load(sess, ACCOUNT_API)
    if err == ERR_API_NOT_EXIST:
        print("FAIL %s err 102 — run the `package` subcommand first" % ACCOUNT_API)
        return 1
    if err is not None:
        print("FAIL %s load failed with err %s" % (ACCOUNT_API, err))
        return 1

    print("LIVE-ACCOUNT-OBJECT " + json.dumps(current)[:1500])
    if a.check:
        print("WOULD-CHANGE privilege -> %s" % json.dumps(groups))
        return 0
    print(
        "FAIL privilege push not implemented: the Management.Account object "
        "shape is unconfirmed (dumped above). Fill in the mapping, then remove "
        "this guard — refusing to guess at an ACCESS-CONTROL payload."
    )
    return 1


# --- publish ------------------------------------------------------------------
CLIENT_TEMPLATE = """\
# OpenVPN client config for {host} — generated by synology_vpn, do not hand-edit.
#
# Import into your OpenVPN client, then mount SMB from {vpn_ip}:
#   macOS/Linux:  smb://{vpn_ip}/<share>
#   Windows:      \\\\{vpn_ip}\\<share>
# Log in with your KRG.LOCAL (AD) username and password.
#
# This tunnel reaches THIS NAS ONLY — no route to the rest of the campus
# network. That is deliberate; see spec/e4e-nas/vpn.yml.
client
dev tun
proto {proto}
remote {host} {port}
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
# Split tunnel: do NOT route all traffic through the NAS.
# (Leave redirect-gateway commented — the service only serves SMB on this box.)
cipher {cipher}
auth {auth_digest}
verb 3
{compression_line}
<ca>
{ca}</ca>
{tls_auth_block}"""

TLS_AUTH_BLOCK = """key-direction 1
<tls-auth>
{ta}</tls-auth>
"""


def _read(path):
    with open(path, "r") as fh:
        return fh.read()


def cmd_publish(a):
    """Render the client .ovpn into a share so users can self-serve it.

    Distributed via the `installers` share (RO @users, RW admins) rather than a
    public URL: with tls_auth on, the file embeds ta.key and is therefore a
    shared secret — it must reach exactly the population that may use the VPN
    (every AD user) and no wider. Users off-campus can still fetch it before
    they have a tunnel, via DSM's web UI / File Station, which is reachable
    US-wide (security.yml `geoip-US-web`). Don't close that without moving this.
    """
    for path in (CA_CRT,) + ((TA_KEY,) if _bool(a.tls_auth) else ()):
        if not os.path.exists(path):
            print("FAIL missing %s — is VPNCenter installed?" % path)
            return 1

    tls_block = ""
    if _bool(a.tls_auth):
        tls_block = TLS_AUTH_BLOCK.format(ta=_read(TA_KEY))

    body = CLIENT_TEMPLATE.format(
        host=a.host,
        port=a.port,
        proto=a.protocol,
        vpn_ip=a.vpn_ip,
        cipher=a.cipher,
        auth_digest=a.auth_digest,
        # comp-lzo is OFF by policy (VORACLE); say so rather than staying silent,
        # since the server default ships it ON and a stale client would mismatch.
        compression_line="# compression disabled by policy (VORACLE)",
        ca=_read(CA_CRT),
        tls_auth_block=tls_block,
    )

    if a.check:
        print("WOULD-CHANGE publish %s (%d bytes)" % (a.dest, len(body)))
        return 0

    dest_dir = os.path.dirname(a.dest)
    if not os.path.isdir(dest_dir):
        print("FAIL destination share %s does not exist" % dest_dir)
        return 1

    if os.path.exists(a.dest) and _read(a.dest) == body:
        print("OK no-change")
        return 0

    tmp = a.dest + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(body)
    # 0644: readable by @users (who have RO on the share) — the file is a shared
    # secret only in the tls-auth sense, and its audience IS every AD user.
    os.chmod(tmp, 0o644)
    os.rename(tmp, a.dest)
    print("CHANGED published %s" % a.dest)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd")

    def _creds(sp):
        # The VPNServer APIs need a real web session (see the DSMSession note).
        # --password may also arrive as DSM_PASSWORD in the env, which is how an
        # operator keeps it off argv; the role passes it on argv with no_log.
        sp.add_argument("--account", default="e4e-admin")
        sp.add_argument("--password", default="")
        return sp

    def _sub(name):
        # --check goes on EACH subparser, not the top level: the role invokes
        # `apply_vpn.py <cmd> --args ... --check`, so a top-level flag would
        # never parse. Matches apply_external_access.py.
        sp = sub.add_parser(name)
        sp.add_argument("--check", action="store_true")
        return sp

    _sub("package")

    o = _creds(_sub("openvpn"))
    o.add_argument("--enable", required=True)
    o.add_argument("--port", required=True)
    o.add_argument("--protocol", required=True)
    o.add_argument("--subnet", required=True)
    o.add_argument("--netmask", required=True)
    o.add_argument("--max-connections", required=True)
    o.add_argument("--allow-lan", required=True)
    o.add_argument("--push-dns", required=True)
    o.add_argument("--ipv6", required=True)
    o.add_argument("--cipher", required=True)
    o.add_argument("--auth-digest", required=True)
    o.add_argument("--compression", required=True)
    o.add_argument("--tls-auth", required=True)
    o.add_argument("--duplicate-cn", required=True)

    v = _creds(_sub("privilege"))
    v.add_argument("--groups", required=True)

    b = _sub("publish")
    b.add_argument("--host", required=True)
    b.add_argument("--vpn-ip", required=True)
    b.add_argument("--port", required=True)
    b.add_argument("--protocol", required=True)
    b.add_argument("--cipher", required=True)
    b.add_argument("--auth-digest", required=True)
    b.add_argument("--tls-auth", required=True)
    b.add_argument("--dest", required=True)

    a = p.parse_args(argv)
    handlers = {
        "package": cmd_package,
        "openvpn": cmd_openvpn,
        "privilege": cmd_privilege,
        "publish": cmd_publish,
    }
    if a.cmd not in handlers:
        p.print_help()
        return 2
    try:
        return handlers[a.cmd](a)
    except (DSMError, RuntimeError, OSError) as e:
        print("FAIL %s" % str(e)[:300])
        return 1


if __name__ == "__main__":
    sys.exit(main())
