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
  auth        point vpnauthd's RADIUS at the AD directory (rad_site_def) and
              template the NetBIOS domain into rad_ntlm_auth. Without this a
              fresh install authenticates LOCAL accounts only and every AD
              login is rejected as "Incorrect user name".
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
import time

WEBAPI = "/usr/syno/bin/synowebapi"
SYNOPKG = "/usr/syno/bin/synopkg"
PKG = "VPNCenter"

CONFIG_API = "SYNO.VPNServer.Settings.Config"
ACCOUNT_API = "SYNO.VPNServer.Management.Account"
SERV_TYPE = "openvpn"

ERR_API_NOT_EXIST = 102  # package stopped -> webapi unregistered
ERR_BAD_PARAMS = 600  # almost always a missing/renamed parameter

KEYS_DIR = "/usr/syno/etc/packages/VPNCenter/openvpn/keys"
# ⚠️ PUBLISH THE BUNDLE, NOT ca.crt. DSM serves the VPN with the DSM SYSTEM
# certificate — here a Let's Encrypt cert for CN=e4e-nas.ucsd.edu — so the
# client must be able to build a chain to a ROOT. `ca.crt` is only the
# INTERMEDIATE (CN=YR2); `ca_bundle.crt` is the full chain
# (YR2 -> ISRG Root YR -> ISRG Root X1).
#
# An `<ca>` block REPLACES the client's trust store rather than adding to it,
# so shipping the intermediate alone leaves no path to a trusted root and every
# connection dies at "VERIFY ERROR: depth=2, unable to get issuer certificate".
# Verified against the live service 2026-08-19: intermediate-only fails, bundle
# gives VERIFY OK at all four depths.
CA_BUNDLE = os.path.join(KEYS_DIR, "ca_bundle.crt")
CA_CRT = os.path.join(KEYS_DIR, "ca.crt")  # fallback only (self-signed setups)
TA_KEY = os.path.join(KEYS_DIR, "ta.key")

# --- The write contract -------------------------------------------------------
# Captured from the DSM UI's own Apply POST (DevTools HAR, 2026-08-17). This is
# the ONLY authoritative source for it: `load` and `apply` do NOT use the same
# schema, and nothing in the package or its libraries says so.
#
# TWO ASYMMETRIES, both of which produced a bare err 600 with no diagnostic:
#
#  1. WRITE-FORBIDDEN FIELDS. `load` returns 19 fields; `apply` accepts 15.
#     serv_run, no_inter_cert and user_conf are read-only state — sending them
#     back (the obvious "full-object push" the other DSM APIs demand) is
#     rejected. So is the integer `serv_type` from the payload; serv_type is
#     only ever the STRING discriminator on the call itself.
#
#  2. FLAGS ARE READ AS INTS AND WRITTEN AS BOOLS. comp_enable comes back as 1
#     and must be sent as true; push_route_enable / tls_auth_key /
#     verify_server_cn / enable_ipv6_server likewise. serv_enable, confusingly,
#     is a real bool in BOTH directions. Coercing everything one way breaks the
#     other; kinds below encode which is which.
#
# kinds:
#   flag  read as 0/1 int, written as bool   (normalise to bool to compare)
#   bool  bool in both directions
#   int   integer
#   str   JSON string
WRITE_FIELDS = (
    ("serv_enable", "bool"),
    ("serv_ip", "str"),
    ("serv_range", "int"),
    ("comp_enable", "flag"),
    ("push_route_enable", "flag"),
    ("tls_auth_key", "flag"),
    ("verify_server_cn", "flag"),
    ("auth_conn", "int"),
    ("port", "int"),
    ("protocol", "str"),
    ("encryption", "str"),
    ("authentication", "str"),
    ("enable_ipv6_server", "flag"),
    ("ipv6_prefix", "str"),
    ("mssfix_value", "int"),
)
WRITE_KIND = dict(WRITE_FIELDS)

# Returned by `load` but REJECTED by `apply`. Named rather than merely omitted
# so the next person sees this is deliberate.
READ_ONLY_FIELDS = ("serv_run", "no_inter_cert", "user_conf", "serv_type")

# spec key -> DSM field. Every one of these is in WRITE_FIELDS; the remaining
# write fields (verify_server_cn, auth_conn, ipv6_prefix, mssfix_value) are not
# spec-managed and pass through from the loaded object unchanged.
FIELDS = {
    "enabled": "serv_enable",
    "port": "port",
    "protocol": "protocol",
    "subnet": "serv_ip",
    "max_connections": "serv_range",
    "allow_lan": "push_route_enable",
    "ipv6": "enable_ipv6_server",
    "cipher": "encryption",
    "auth_digest": "authentication",
    "compression": "comp_enable",
    "tls_auth": "tls_auth_key",
}

# Spec keys with NO equivalent in this API — asserted so a future edit to
# vpn.yml doesn't silently expect them to be applied:
#   netmask         the mask is implied; `serv_range` is max-clients, not a range
#   push_dns        not exposed
#   duplicate_cn    real, but lives only in openvpn.conf — not settable here
#   tls_min_version not exposed
#   topology        not exposed; DSM inherits OpenVPN's net30 default. vpn.yml
#                   records the OBSERVED value so client authors do not have to
#                   packet-capture for it — it is documentation, not config.
UNSUPPORTED = ("netmask", "push_dns", "duplicate_cn", "tls_min_version", "topology")


def _run(cmd, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


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


def _norm(field, value):
    """Canonical form for COMPARISON. Flags are ints on read and bools on write,
    so both sides are normalised to bool before diffing — otherwise 1 != True
    and the role reports CHANGED forever."""
    kind = WRITE_KIND.get(field, "str")
    if kind in ("flag", "bool"):
        return value if isinstance(value, bool) else _bool(value)
    if kind == "int":
        return int(value)
    return str(value)


def _wire(field, value):
    """Value as DSM's `apply` wants it on the wire (see WRITE_FIELDS)."""
    kind = WRITE_KIND.get(field, "str")
    if kind in ("flag", "bool"):
        return value if isinstance(value, bool) else _bool(value)
    if kind == "int":
        return int(value)
    return str(value)


def _fmt(value):
    """synowebapi --exec parses key=value as JSON, so bare strings must be
    JSON-quoted or DSM drops them (3103) / truncates them (4302)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value)


def _apply(api, merged):
    """Send EXACTLY the fields DSM's apply accepts, in the UI's own order.

    Anything outside WRITE_FIELDS is dropped — including the read-only trio the
    load payload carries. Sending them is what produced err 600.
    """
    params = ['serv_type="%s"' % SERV_TYPE]
    for field, _kind in WRITE_FIELDS:
        if field not in merged:
            raise RuntimeError(
                "apply is missing required field %r — the live object did not "
                "provide it and it is not spec-managed" % field
            )
        params.append("%s=%s" % (field, _fmt(_wire(field, merged[field]))))
    resp = _exec(api, "version=1", "method=apply", *params)
    if not resp.get("success", False):
        err = json.dumps(resp.get("error"))
        raise RuntimeError(
            "%s apply failed: %s (600 here means a rejected field or type — "
            "compare against WRITE_FIELDS)" % (api, err)
        )
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

    desired = {FIELDS[skey]: raw for skey, raw in spec.items()}

    unknown = [k for k in desired if k not in current]
    if unknown:
        # Loud, not silent: a stale mapping would otherwise "succeed" while
        # configuring nothing, and the operator would find an unconfigured VPN.
        print(
            "FAIL field mismatch — %s not present in the live object. Live keys: %s"
            % (sorted(unknown), sorted(current.keys()))
        )
        return 1

    # Diff in NORMALISED space: flags come back as 0/1 ints but are written as
    # bools, so a raw comparison would see 1 != True and never converge.
    drift = {
        field: _norm(field, raw)
        for field, raw in desired.items()
        if _norm(field, current[field]) != _norm(field, raw)
    }
    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(sorted(drift.keys())))
        return 0

    # Overlay our fields onto the loaded object; _apply then sends only the
    # subset DSM's write contract accepts (WRITE_FIELDS), so the unmanaged
    # fields ride through unchanged and the read-only ones are dropped.
    merged = dict(current)
    merged.update(desired)
    _apply(CONFIG_API, merged)
    print("CHANGED " + json.dumps(sorted(drift.keys())))
    return 0


# --- privilege ----------------------------------------------------------------
# CAPTURED FROM THE UI 2026-08-17 (DevTools HAR). The privilege model is NOT
# what the spec originally assumed, and the difference is load-bearing:
#
#   * `Management.Account` enumerates LOCAL ACCOUNTS ONLY. On this box
#     (AD-joined, thousands of domain users available) `load` returns total=4:
#     admin, e4e-admin, e4e-automation, guest. There is NO AD-user and NO
#     AD-group privilege surface — not here, and not in SYNO.Core.AppPriv,
#     which still lists no VPN application after the package is installed.
#
#   * So "grant the VPN to KRG\Domain Users" is NOT EXPRESSIBLE. AD users are
#     admitted by the auth path itself (OpenVPN -> radiusplugin -> radiusd ->
#     ntlm_auth -> winbind -> DC), with no per-user allowlist in front of it.
#     "Any authorised AD user" is therefore not a policy choice we made — it is
#     the only behaviour DSM offers. The compensating controls are the ones
#     already in the spec: tls_auth, geoip-scoped 1194, DSM auto-block, and the
#     12-char AD password policy.
#
#   * What IS controllable is the LOCAL accounts, and DSM ships them all
#     ENABLED for every protocol. Live before this role ran: admin,
#     e4e-admin, e4e-automation and guest all enable_ovpn=True. e4e-admin and
#     e4e-automation are active `administrators` accounts, so that is a
#     password-authenticated internet front door into two admin accounts —
#     exactly what key-only SSH exists to prevent. Denying them is the whole
#     job of this subcommand.
#
# READ/WRITE ASYMMETRY (again): `load` returns items keyed `username` with a
# `status` field; `apply` takes `priv=[{name, enable_pptp, enable_l2tp,
# enable_ovpn}]` — key renamed, status dropped.
def cmd_privilege(a):
    """Deny every local account access to every VPN protocol.

    Deliberately not a grant: there is nothing to grant to (see above). The
    spec's `deny_local` list names the accounts to lock out; `all` means every
    account Management.Account enumerates, which is the correct default because
    everything it can see IS a local account.
    """
    deny = json.loads(a.deny_local) if a.deny_local else []
    if not isinstance(deny, list):
        print('FAIL --deny-local must be a JSON list (or ["all"])')
        return 1

    resp = _exec(ACCOUNT_API, "version=1", "method=load", 'action="enum"', "start=0", "limit=200")
    if not resp.get("success", False):
        print(
            "FAIL %s load failed with err %s" % (ACCOUNT_API, (resp.get("error") or {}).get("code"))
        )
        return 1
    items = (resp.get("data") or {}).get("items") or []
    if not items:
        print("FAIL %s returned no accounts" % ACCOUNT_API)
        return 1

    deny_all = "all" in deny
    priv, drift = [], []
    for it in items:
        user = it.get("username")
        locked = deny_all or user in deny
        want = {
            "name": user,  # NOTE: `name` on write, `username` on read
            "enable_pptp": False,  # pptp/l2tp are off at the server level
            "enable_l2tp": False,  # too; deny per-account as well
            "enable_ovpn": not locked,
        }
        priv.append(want)
        for wire_key, read_key in (
            ("enable_ovpn", "enable_ovpn"),
            ("enable_l2tp", "enable_l2tp"),
            ("enable_pptp", "enable_pptp"),
        ):
            if bool(it.get(read_key)) != want[wire_key]:
                drift.append("%s.%s" % (user, wire_key))

    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(sorted(drift)))
        return 0

    resp = _exec(
        ACCOUNT_API,
        "version=1",
        "method=apply",
        "priv=" + json.dumps(priv, separators=(",", ":")),
    )
    if not resp.get("success", False):
        print("FAIL %s apply failed: %s" % (ACCOUNT_API, json.dumps(resp.get("error"))))
        return 1
    print("CHANGED " + json.dumps(sorted(drift)))
    return 0


# --- service ------------------------------------------------------------------
def cmd_service(a):
    """Reconcile the DAEMON against the CONFIG.

    Settings.Config.apply writes `serv_enable` but does NOT start openvpn:
    after a successful apply the box sits at serv_enable=True, serv_run=False,
    nothing bound to 1194 (observed 2026-08-17). The package has to be bounced
    to pick the config up.

    Declarative, not a one-shot: it restarts ONLY when the config says the
    service should be up and the daemon isn't. A converged box reports
    no-change, so this is safe to run every time.
    """
    current, err = _load(CONFIG_API)
    if err is not None:
        print("FAIL %s load failed with err %s" % (CONFIG_API, err))
        return 1

    want_up = _norm("serv_enable", current.get("serv_enable", False))
    running = bool(current.get("serv_run", False))

    if not want_up:
        # Spec disables the server; the daemon being down is the desired state.
        print("OK no-change openvpn disabled")
        return 0
    if running:
        print("OK no-change openvpn running")
        return 0
    if a.check:
        print("WOULD-CHANGE restart %s to start openvpn" % PKG)
        return 0

    out = _run([SYNOPKG, "restart", PKG])
    if out.returncode != 0:
        print("FAIL could not restart %s: %s" % (PKG, (out.stderr or out.stdout).strip()[:200]))
        return 1
    print("CHANGED restarted %s to start openvpn" % PKG)
    return 0


# --- auth backend (which directory vpnauthd actually asks) --------------------
# THE BUG THIS EXISTS TO FIX (found 2026-08-25, first off-campus test):
# every AD login was rejected with
#
#     radius.log: Login incorrect: Incorrect user name [c.crutchfield.642]
#
# — "user not found", not "wrong password". VPN Server was authenticating
# against LOCAL DSM accounts only, so no domain principal could ever match.
#
# WHY. VPNCenter's FreeRADIUS (vpnauthd) picks its directory backend from ONE
# include file, `syno_conf/rad_site_def`, which selects one of three shipped
# sites:
#     rad_site_def_local   unix + smbpasswd          <- what we were running
#     rad_site_def_ad      Auth-Type := ntlm_auth    <- what an AD box needs
#     rad_site_def_ldap    rlm_ldap
# `scripts/postinst` copies the shipped default, which points at _local, and
# NOTHING in the install path ever revisits it. The only thing that switches it
# to _ad is `bin/vpn_updater`, and that runs from `postupgrade` / backup-import
# only. So the AD backend is selected as a side effect of UPGRADING the package
# on an already-joined box — install it fresh onto a joined NAS, as terraform
# did here on 2026-08-15, and the switch never happens. Verified on-box: every
# file in syno_conf still carried its 18:27 install mtime, untouched by the
# Aug-17 Settings.Config apply.
#
# This is why spec/e4e-nas/vpn.yml's "AD users are admitted by the auth path
# itself, with no allowlist in front of it" was true in design and false in
# fact — the path existed but was pointed at the wrong directory. Combined with
# `deny_local: ["all"]` (correctly locking out admin/e4e-admin/e4e-automation/
# guest), the service was closed to literally everyone.
#
# The second half of the same defect: `rad_ntlm_auth` still held the shipped
# placeholder `--domain=MYDOMAIN`. vpn_updater's job is to rewrite that with the
# real workgroup, so it was never templated either.
#
# So this subcommand reconciles both files from the spec, every run. It is not a
# one-shot repair: a DSM or package update restores the vendor defaults, and the
# next apply puts them back — which is the whole reason it lives here rather
# than in a runbook.
SYNO_CONF_DIR = "/usr/syno/etc/packages/VPNCenter/syno_conf"
RAD_SITE_DEF = os.path.join(SYNO_CONF_DIR, "rad_site_def")
RAD_NTLM_AUTH = os.path.join(SYNO_CONF_DIR, "rad_ntlm_auth")
# The path the SHIPPED rad_site_def uses in its $INCLUDE. /var/packages/
# VPNCenter/etc and /usr/syno/etc/packages/VPNCenter are the same directory
# (both symlink to /volume1/@appconf/VPNCenter — same inode, verified on-box);
# we emit the vendor's spelling so a diff against a stock box is empty.
SITE_INCLUDE_DIR = "/var/packages/VPNCenter/etc/syno_conf"
RADIUSD_SH = "/var/packages/VPNCenter/target/scripts/radiusd.sh"
SYNOVPN_CONF = "/usr/syno/etc/packages/VPNCenter/synovpn.conf"
SMB_CONF = "/etc/samba/smb.conf"
SYNOINFO_CONF = "/etc/synoinfo.conf"

BACKENDS = ("ad", "local")

# FreeRADIUS xlat, not python: %{%{Realm}:-KRG} is "Realm if the client sent
# DOMAIN\user, else the default". rad_site_def_ad's authorize block sets Realm
# from a leading `KRG\`, so BOTH `KRG\c.user.123` and a bare `c.user.123`
# resolve to the same domain — which matters because clients disagree about
# whether to send the prefix. @@DOMAIN@@ is substituted rather than %-formatted
# precisely because the literal braces would fight str.format/%.
NTLM_PROGRAM_TEMPLATE = (
    'program = "/usr/local/bin/ntlm_auth --request-nt-key '
    "--domain=%{%{Realm}:-@@DOMAIN@@} "
    "--username=%{mschap:User-Name} "
    '--password=%{User-Password}"\n'
)


def _read_if(path):
    try:
        with open(path, "r") as fh:
            return fh.read()
    except OSError:
        return None


def _key_value(path, key):
    """Read a `key=value` / `key = "value"` line out of a DSM conf file.

    Used for smb.conf `workgroup` and synoinfo.conf `domainjoined`. Deliberately
    not a shell-out to /bin/get_key_value: this has to be unit-testable off-box.
    """
    text = _read_if(path)
    if text is None:
        return None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or stripped.startswith(";") or "=" not in stripped:
            continue
        name, _, value = stripped.partition("=")
        if name.strip().lower() == key.lower():
            return value.strip().strip('"').strip("'")
    return None


def _site_def(backend):
    return "$INCLUDE %s/rad_site_def_%s\n" % (SITE_INCLUDE_DIR, backend)


def _write_conf(path, body):
    """Replace a syno_conf file atomically at 0600 (radiusd.sh chmods the whole
    directory to 600 on start; matching it keeps the run a no-op)."""
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(body)
    os.chmod(tmp, 0o600)
    os.rename(tmp, path)


# --- bouncing vpnauthd, and knowing whether it worked ------------------------
# TWO TRAPS, both paid for on the first real apply (2026-08-25):
#
# 1. radiusd.sh CALLS `synosystemctl` UNQUALIFIED. Under ansible's `script:`
#    module the remote PATH is a bare non-login one with no /usr/syno/bin, so
#    the command is not found, `$(synosystemctl get-active-status ...)` returns
#    "", the `[ "active" == "" ]` guard is false, the stop is SKIPPED — and the
#    script still `exit 0`s. Same class as [[deploy-runner-strict-path-missing-tool]].
#    Hence the explicit PATH below; every direct DSM call in this file already
#    uses an absolute path for the same reason.
#
# 2. rc 0 FROM THAT SCRIPT MEANS NOTHING. It exits 0 whether it restarted the
#    daemon, no-opped, or failed every command inside. The first apply reported
#    "CHANGED (vpnauthd restarted)" while vpnauthd kept the same PID from eight
#    days earlier — files converged, daemon still serving the OLD site, and the
#    role would have gone green forever. So the restart is VERIFIED by pid
#    change, not trusted.
SYNO_PATH = "/usr/syno/sbin:/usr/syno/bin"
PROC_DIR = "/proc"
VPNAUTHD_COMM = "vpnauthd"
RESTART_TIMEOUT_S = 20.0


def _pids_named(comm):
    """PIDs whose /proc/<pid>/comm matches. Avoids pidof/pgrep, which DSM does
    not reliably ship, and is trivially fakeable in tests."""
    pids = []
    try:
        entries = os.listdir(PROC_DIR)
    except OSError:
        return pids
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open(os.path.join(PROC_DIR, entry, "comm"), "r") as fh:
                if fh.read().strip() == comm:
                    pids.append(int(entry))
        except OSError:
            continue  # process exited between listdir and open
    return sorted(pids)


def _proc_started(pid):
    """Process start time. /proc/<pid>'s own mtime is set when the process is
    created, which is all we need and needs no btime/HZ arithmetic."""
    return os.path.getmtime(os.path.join(PROC_DIR, str(pid)))


def _daemon_is_stale(paths):
    """True when vpnauthd is down, or older than the config it should be serving.

    This is what makes the subcommand converge rather than merely apply: after a
    run that wrote the files but failed to bounce the daemon, the FILES are
    correct, so file-drift alone reports no-change and the box stays broken.
    Comparing against process start time catches exactly that.
    """
    pids = _pids_named(VPNAUTHD_COMM)
    if not pids:
        return True
    started = min(_proc_started(p) for p in pids)
    live = [p for p in paths if os.path.exists(p)]
    return any(os.path.getmtime(p) > started for p in live)


def _restart_vpnauthd():
    """Bounce vpnauthd and PROVE it happened. Returns (ok, detail)."""
    before = set(_pids_named(VPNAUTHD_COMM))
    env = dict(os.environ)
    env["PATH"] = SYNO_PATH + ":" + env.get("PATH", "")
    out = _run(["/bin/sh", RADIUSD_SH, "force-restart"], env=env)

    deadline = time.time() + RESTART_TIMEOUT_S
    while True:
        now = set(_pids_named(VPNAUTHD_COMM))
        if now and not (now & before):
            return True, "vpnauthd restarted (pid %s -> %s)" % (
                sorted(before) or "none",
                sorted(now),
            )
        if time.time() >= deadline:
            break
        time.sleep(0.5)

    now = set(_pids_named(VPNAUTHD_COMM))
    if not now:
        return False, "vpnauthd did not come back up (rc=%s): %s" % (
            out.returncode,
            (out.stderr or out.stdout).strip()[:200],
        )
    return False, (
        "vpnauthd still running as pid %s after %ss — the restart no-opped, so "
        "it is STILL SERVING THE OLD RADIUS SITE (rc=%s, which this script "
        "always returns): %s"
        % (
            sorted(now),
            int(RESTART_TIMEOUT_S),
            out.returncode,
            (out.stderr or out.stdout).strip()[:200],
        )
    )


def cmd_auth(a):
    """Point vpnauthd at the directory the spec says, and template the domain.

    Idempotent: both files are compared before writing, and vpnauthd is bounced
    only when something actually changed.
    """
    backend = (a.backend or "").strip().lower()
    if backend not in BACKENDS:
        print("FAIL --backend must be one of %s, got %r" % (list(BACKENDS), a.backend))
        return 1

    site_path = os.path.join(SYNO_CONF_DIR, "rad_site_def_%s" % backend)
    if not os.path.exists(site_path):
        print("FAIL %s does not exist — is VPNCenter installed?" % site_path)
        return 1

    domain = (a.domain or "").strip()
    if backend == "ad":
        # Fail rather than guess. An AD site on a box that is not joined rejects
        # EVERY user (ntlm_auth has no winbind to ask), which is the same
        # symptom as the bug this subcommand fixes — so refuse to create it.
        joined = (_key_value(SYNOINFO_CONF, "domainjoined") or "").lower()
        if joined != "yes":
            print(
                "FAIL backend=ad but DSM reports domainjoined=%r — the AD RADIUS "
                "site would reject every user. Run synology_ad first." % joined
            )
            return 1
        if not domain:
            domain = _key_value(SMB_CONF, "workgroup") or ""
        if not domain:
            print(
                "FAIL backend=ad needs a NetBIOS domain: none given and no "
                "`workgroup` in %s" % SMB_CONF
            )
            return 1

    want = {RAD_SITE_DEF: _site_def(backend)}
    if backend == "ad":
        want[RAD_NTLM_AUTH] = NTLM_PROGRAM_TEMPLATE.replace("@@DOMAIN@@", domain)

    drift = []
    for path, body in sorted(want.items()):
        current = _read_if(path)
        if current is None:
            drift.append(os.path.basename(path) + " (missing)")
        elif current.strip() != body.strip():
            # `rad_site_def` shipped pointing at _local; report WHICH site is
            # live so the deploy log says what changed, not just that it did.
            drift.append(os.path.basename(path))

    # A converged FILE is not a converged SERVICE. vpnauthd reads its site once,
    # at start, so a run that wrote the files but failed to bounce it leaves the
    # box broken with nothing left to diff. Treat that as drift too.
    stale = _daemon_is_stale(sorted(want.keys()))
    if stale and not drift:
        drift.append("vpnauthd (running older than its config)")

    if not drift:
        print("OK no-change auth backend=%s" % backend)
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(sorted(drift)))
        return 0

    for path, body in sorted(want.items()):
        _write_conf(path, body)

    # Only bounce when a protocol is enabled: radiusd.sh's start branch exits 0
    # without starting if synovpn.conf has no `yes`, so bouncing a disabled box
    # would stop vpnauthd and not bring it back.
    protocols = [_key_value(SYNOVPN_CONF, k) for k in ("runopenvpn", "runpptpd", "runl2tpd")]
    if not any((p or "").lower() == "yes" for p in protocols):
        print(
            "CHANGED %s (no protocol enabled — vpnauthd not bounced, it will "
            "read the new site when it next starts)" % json.dumps(sorted(drift))
        )
        return 0

    ok, detail = _restart_vpnauthd()
    if not ok:
        # Loud AND non-zero: the files are right but the daemon is still on the
        # old site, so authentication behaviour has NOT changed. Reporting this
        # green is how the first apply hid itself.
        print("FAIL wrote %s but %s" % (json.dumps(sorted(drift)), detail))
        return 1
    print("CHANGED " + json.dumps(sorted(drift)) + " — " + detail)
    return 0


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
# Log in with your KRG.LOCAL (AD) account, DOMAIN-QUALIFIED:
#
#   Username:  KRG\\<your-ad-username>      e.g.  KRG\\a.researcher.123
#   Password:  your AD password
#
# The `KRG\\` prefix is REQUIRED. Without it the NAS rejects you as "Incorrect
# user name" before it ever checks your password, because VPN Server matches an
# unqualified name against LOCAL NAS accounts only.
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
# The server presents the DSM system certificate, which is issued by a PUBLIC
# CA (Let's Encrypt). Chain validation alone would therefore accept ANY
# LE-issued certificate, so an attacker able to redirect traffic could present
# their own and MITM the tunnel. These two lines close that:
#   remote-cert-tls server  — the peer cert must carry the TLS-server EKU
#   verify-x509-name        — and its subject must be exactly this host
remote-cert-tls server
verify-x509-name {host} name
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
    # Full chain if DSM has one (it does whenever the VPN uses the system
    # certificate); ca.crt alone only suffices for a self-signed setup.
    ca_path = CA_BUNDLE if os.path.exists(CA_BUNDLE) else CA_CRT
    for path in (ca_path,) + ((TA_KEY,) if _bool(a.tls_auth) else ()):
        if not os.path.exists(path):
            print("FAIL missing %s — is VPNCenter installed?" % path)
            return 1

    ca_pem = _read(ca_path)
    # A single certificate here means no path to a root, which fails EVERY
    # client at depth=2 — the failure this check exists to prevent recurring.
    if ca_path == CA_BUNDLE and ca_pem.count("BEGIN CERTIFICATE") < 2:
        print(
            "FAIL %s holds only %d certificate(s) — expected a chain. Clients "
            "cannot verify a publicly-issued server cert without one."
            % (CA_BUNDLE, ca_pem.count("BEGIN CERTIFICATE"))
        )
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
        ca=ca_pem,
        tls_auth_block=tls_block,
    )

    dest_dir = os.path.dirname(a.dest)
    if not os.path.isdir(dest_dir):
        print("FAIL destination share %s does not exist" % dest_dir)
        return 1
    # Compare BEFORE honouring --check: returning WOULD-CHANGE unconditionally
    # made `--check --diff` report a change on an already-converged file, which
    # is exactly the signal a dry run exists to give honestly.
    if os.path.exists(a.dest) and _read(a.dest) == body:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE publish %s (%d bytes)" % (a.dest, len(body)))
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
    _sub("service")

    t = _sub("auth")
    t.add_argument("--backend", required=True)
    t.add_argument("--domain", default="")

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
    v.add_argument("--deny-local", required=True)

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
        "service": cmd_service,
        "auth": cmd_auth,
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
