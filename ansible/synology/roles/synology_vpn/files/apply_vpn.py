#!/usr/bin/env python3
"""Apply DSM VPN Server (OpenVPN) config idempotently from spec/e4e-nas/vpn.yml.

Invoked by the synology_vpn ansible role via `script` (DSM ships py3.8, below
ansible's module floor — see [[synology-script-raw-pattern]]).

Subcommands:

  package     ensure the VPNCenter package is RUNNING (synopkg). Must run first:
              DSM leaves VPN Server stopped after install, and while stopped its
              webapi is not registered at all (err 102).
  openvpn     SYNO.VPNServer.Settings.Config   load -> overlay -> apply
  privilege   SYNO.VPNServer.Management.Account load -> overlay -> apply
  dump        read-only schema print; never fails (used to capture the schema
              from CD without anyone handling a password)
  publish     render the client .ovpn into a share so users can self-serve it

TWO THINGS THIS API DOES THAT COST US A DAY, WRITTEN DOWN SO THEY DON'T AGAIN:

1. `serv_type` IS MANDATORY. Every Settings.Config call needs
   serv_type="openvpn" (the package also serves "pptp" and "l2tp"). Omit it and
   DSM returns **err 600**, with no hint that a parameter is missing. 600 was
   originally misread as "this API needs an authenticated web session" — by
   analogy with SYNO.Core.Security.Firewall.Profile, which genuinely does — and
   a whole inlined HTTP client was written against that theory before a
   parameter sweep showed the CLI runner works fine. If you see 600 here, the
   first suspicion is a missing/renamed parameter, NOT the transport.

2. THE PAYLOAD IS NESTED. `load` returns {"data": {"items": {...}}}, so the
   fields live at data.items, not data.

FIELD TYPES ARE NOT UNIFORM, and this matters for idempotence. `serv_enable`
and `no_inter_cert` and `user_conf` come back as JSON booleans, while
`comp_enable`, `push_route_enable`, `tls_auth_key` and `enable_ipv6_server`
come back as 0/1 INTEGERS. Push a bool where DSM stores an int and the value is
accepted but never compares equal on the next run — the role reports CHANGED
forever and never converges. FIELDS below therefore carries an explicit kind
per field, and every value is coerced before comparison AND before push.

Captured live from e4e-nas (DSM 7.3.2, VPNCenter 1.4.10-2984, 2026-08-16):
    auth_conn 3 | authentication 'SHA512' | comp_enable 1 | enable_ipv6_server 0
    encryption 'AUTO' | ipv6_prefix '' | mssfix_value 1450 | no_inter_cert False
    port 1194 | protocol 'udp' | push_route_enable 0 | serv_enable False
    serv_ip '10.8.0.0' | serv_range 5 | serv_run False | serv_type 3
    tls_auth_key 0 | user_conf False | verify_server_cn 0
"""

import argparse
import json
import os
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SYNOPKG = "/usr/syno/bin/synopkg"
PKG = "VPNCenter"

CONFIG_API = "SYNO.VPNServer.Settings.Config"
ACCOUNT_API = "SYNO.VPNServer.Management.Account"
SERV_TYPE = "openvpn"

ERR_API_NOT_EXIST = 102  # package stopped -> webapi unregistered
ERR_BAD_PARAMS = 600  # almost always a missing/renamed parameter

KEYS_DIR = "/usr/syno/etc/packages/VPNCenter/openvpn/keys"
CA_CRT = os.path.join(KEYS_DIR, "ca.crt")
TA_KEY = os.path.join(KEYS_DIR, "ta.key")

# spec key -> (DSM field, kind). kind drives coercion; see the docstring.
#   bool   real JSON boolean
#   int01  0/1 integer used as a flag
#   int    plain integer
#   str    string
FIELDS = {
    "enabled": ("serv_enable", "bool"),
    "port": ("port", "int"),
    "protocol": ("protocol", "str"),
    "subnet": ("serv_ip", "str"),
    "max_connections": ("serv_range", "int"),
    "allow_lan": ("push_route_enable", "int01"),
    "ipv6": ("enable_ipv6_server", "int01"),
    "cipher": ("encryption", "str"),
    "auth_digest": ("authentication", "str"),
    "compression": ("comp_enable", "int01"),
    "tls_auth": ("tls_auth_key", "int01"),
}

# Spec keys with NO equivalent in this API — asserted here so a future edit to
# vpn.yml doesn't silently expect them to be applied:
#   netmask         the mask is implied; `serv_range` is max-clients, not a range
#   push_dns        not exposed
#   duplicate_cn    real, but lives only in openvpn.conf — not settable here
#   tls_min_version not exposed
UNSUPPORTED = ("netmask", "push_dns", "duplicate_cn", "tls_min_version")


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def _exec(api, *params):
    out = _run([WEBAPI, "--exec", "api=" + api, *params])
    # synowebapi prefixes diagnostics like `[Line 295] Exec WebAPI: ... param={...}`
    # which CONTAINS a brace — scanning for the first `{` finds the wrong object.
    lines = [ln for ln in out.stdout.splitlines() if not ln.startswith("[Line")]
    txt = "\n".join(lines)
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (out.stdout or out.stderr))
    return json.loads(txt[brace:])


def _load(api):
    """`load` the current object. Returns (items, None) or (None, err_code)."""
    resp = _exec(api, "version=1", "method=load", 'serv_type="%s"' % SERV_TYPE)
    if not resp.get("success", False):
        return None, (resp.get("error") or {}).get("code")
    data = resp.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("%s load: success but no data: %s" % (api, json.dumps(resp)))
    # Fields are nested under data.items (see docstring).
    return data.get("items", data), None


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _coerce(kind, value):
    if kind == "bool":
        return _bool(value) if not isinstance(value, bool) else value
    if kind == "int01":
        return 1 if (_bool(value) if not isinstance(value, bool) else value) else 0
    if kind == "int":
        return int(value)
    return str(value)


def _fmt(value):
    """synowebapi --exec parses key=value as JSON, so bare strings must be
    JSON-quoted or DSM drops them (3103) / truncates them (4302)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value)


def _apply(api, items):
    params = ['serv_type="%s"' % SERV_TYPE]
    params += ["%s=%s" % (k, _fmt(v)) for k, v in sorted(items.items())]
    resp = _exec(api, "version=1", "method=apply", *params)
    if not resp.get("success", False):
        raise RuntimeError("%s apply failed: %s" % (api, json.dumps(resp.get("error"))))
    return resp


# --- package ------------------------------------------------------------------
def cmd_package(a):
    """Ensure VPNCenter is installed AND running. Installation is terraform's
    job (terraform/e4e-nas/packages.tf); this only starts it."""
    st = _run([SYNOPKG, "status", PKG])
    # synopkg's EXIT CODE is not an install check. Measured on DSM 7.3.2:
    #   installed but stopped -> rc 17
    #   not installed         -> rc 255, aspect.error.status == "non_installed"
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
    # DSM's running sentinel is "running" — NOT "start", which was guessed and
    # never verified. Measured: stopped -> "stop" (rc 17), running -> "running"
    # (rc 0). Matching only "start" made this report CHANGED on every run and
    # re-issue `synopkg start` against an already-running package.
    if status in ("running", "start", "started"):
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
    spec = {
        "enabled": a.enable,
        "port": a.port,
        "protocol": a.protocol,
        "subnet": a.subnet,
        "max_connections": a.max_connections,
        "allow_lan": a.allow_lan,
        "ipv6": a.ipv6,
        "cipher": a.cipher,
        "auth_digest": a.auth_digest,
        "compression": a.compression,
        "tls_auth": a.tls_auth,
    }

    # Refuse to push a config that would turn the NAS into a router onto the
    # campus network. This is the ONE setting whose failure mode is a security
    # incident rather than a broken service, so it is enforced here as well as
    # documented in the spec — a typo in vpn.yml must not be able to do it.
    if _bool(spec["allow_lan"]):
        print(
            "FAIL refusing allow_lan=true: it makes DSM push a LAN route "
            "(push_route_enable) and forward, turning e4e-nas into a gateway "
            "onto the flat-public campus subnet. See spec/e4e-nas/vpn.yml."
        )
        return 1

    current, err = _load(CONFIG_API)
    if err == ERR_API_NOT_EXIST:
        print(
            "FAIL %s err 102 — the VPNCenter package is stopped (its webapi "
            "only registers while running). Run the `package` subcommand first." % CONFIG_API
        )
        return 1
    if err == ERR_BAD_PARAMS:
        print(
            "FAIL %s err 600 — DSM rejected the parameters. This is NOT a "
            "transport/session problem: suspect a missing or renamed field "
            "(serv_type is mandatory). Run the `dump` subcommand." % CONFIG_API
        )
        return 1
    if err is not None:
        print("FAIL %s load failed with err %s" % (CONFIG_API, err))
        return 1

    desired = {}
    for skey, raw in spec.items():
        field, kind = FIELDS[skey]
        desired[field] = _coerce(kind, raw)

    unknown = [k for k in desired if k not in current]
    if unknown:
        # Loud, not silent: a stale mapping would otherwise "succeed" while
        # configuring nothing, and the operator would find an unconfigured VPN.
        print(
            "FAIL field mismatch — %s not present in the live object. Live keys: %s"
            % (sorted(unknown), sorted(current.keys()))
        )
        return 1

    drift = {k: v for k, v in desired.items() if current.get(k) != v}
    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(sorted(drift.keys())))
        return 0

    # Full-object push: DSM's *.apply surfaces reject partial objects (err 2001),
    # so send the loaded object with our fields overlaid.
    target = dict(current)
    target.update(desired)
    _apply(CONFIG_API, target)
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

    current, err = _load(ACCOUNT_API)
    if err is not None:
        print("FAIL %s load failed with err %s (run `dump`)" % (ACCOUNT_API, err))
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


# --- dump (read-only schema capture) ------------------------------------------
# Kept (off by default) because it is what broke the err-600 deadlock: it proved
# the failure was NOT transport-related, which is what sent us looking for a
# missing parameter. Cheap insurance for the next unexplained code.
_REDACT = ("pass", "secret", "key", "token", "cert", "priv", "hash", "seed")


def _redact(obj):
    if not isinstance(obj, dict):
        return obj
    out = {}
    for k, v in obj.items():
        if any(w in k.lower() for w in _REDACT):
            out[k] = "<redacted>"
        elif isinstance(v, dict):
            out[k] = _redact(v)
        else:
            out[k] = v
    return out


def cmd_dump(a):
    """Print the live schema. NEVER returns non-zero: this can run unattended
    and must not be able to break a deploy. Output avoids the FAIL/CHANGED
    sentinels the role greps for — a dump is neither a failure nor a change."""
    for api in (CONFIG_API, ACCOUNT_API):
        try:
            data, err = _load(api)
            if err is not None:
                print("SCHEMA %s unavailable err=%s" % (api, err))
                continue
            print("SCHEMA %s keys=%s" % (api, json.dumps(sorted(data.keys()))))
            print("SCHEMA %s values=%s" % (api, json.dumps(_redact(data), sort_keys=True)[:4000]))
        except Exception as e:  # noqa: BLE001 - must never break the deploy
            print("SCHEMA %s dump-error: %s" % (api, str(e)[:200]))
    return 0


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

    tls_block = TLS_AUTH_BLOCK.format(ta=_read(TA_KEY)) if _bool(a.tls_auth) else ""

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
    # 0644: readable by @users (who have RO on the share). The file is a shared
    # secret only in the tls-auth sense, and its audience IS every AD user.
    os.chmod(tmp, 0o644)
    os.rename(tmp, a.dest)
    print("CHANGED published %s" % a.dest)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd")

    def _sub(name):
        # --check goes on EACH subparser, not the top level: the role invokes
        # `apply_vpn.py <cmd> --args ... --check`, so a top-level flag would
        # never parse. Matches apply_external_access.py.
        sp = sub.add_parser(name)
        sp.add_argument("--check", action="store_true")
        return sp

    _sub("package")
    _sub("dump")

    o = _sub("openvpn")
    for flag in (
        "--enable",
        "--port",
        "--protocol",
        "--subnet",
        "--max-connections",
        "--allow-lan",
        "--ipv6",
        "--cipher",
        "--auth-digest",
        "--compression",
        "--tls-auth",
    ):
        o.add_argument(flag, required=True)

    v = _sub("privilege")
    v.add_argument("--groups", required=True)

    b = _sub("publish")
    for flag in (
        "--host",
        "--vpn-ip",
        "--port",
        "--protocol",
        "--cipher",
        "--auth-digest",
        "--tls-auth",
        "--dest",
    ):
        b.add_argument(flag, required=True)

    a = p.parse_args(argv)
    handlers = {
        "package": cmd_package,
        "openvpn": cmd_openvpn,
        "privilege": cmd_privilege,
        "dump": cmd_dump,
        "publish": cmd_publish,
    }
    if a.cmd not in handlers:
        p.print_help()
        return 2
    try:
        return handlers[a.cmd](a)
    except (RuntimeError, OSError, ValueError) as e:
        print("FAIL %s" % str(e)[:300])
        return 1


if __name__ == "__main__":
    sys.exit(main())
