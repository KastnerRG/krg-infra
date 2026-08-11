#!/usr/bin/env python3
"""Apply DSM system-level config idempotently via synowebapi.

Subcommands:
  network           SYNO.Core.Network v2 set (full-object) — hostname/gateway/DNS.
                    Static interface IP/netmask lives on .Ethernet (per-interface
                    set v2); reserved subcommand, typically no-ops because the live
                    IP `132.239.17.124/16` already matches the spec.
  package-defaults  SYNO.Core.Package.Setting v1 set — `default_vol` (the Package
                    Center "default install volume"). Prerequisite for the
                    `synology_core_package` Terraform resource — the provider
                    calls Package.Setting.get and bails with "default volume
                    empty" if this isn't set. Validated 2026-06-02 on e4e-nas:
                    DSM accepts the param `default_vol` (NOT the synoinfo.conf
                    `default_install_vol` key, which is silently ignored by the
                    SET path on DSM 7.3).
  package-state     `synopkg start <pkg>` for each package the spec marks as
                    `ensure_running`. WORKAROUND for an upstream bug in
                    `synology-community/go-synology` PackageInstallCompound: the
                    library's PackageInstallRequest hardcodes
                    InstallRunPackage=false and ignores req.Run, so the
                    Terraform `synology_core_package` resource's `run=true`
                    attribute is silently dropped — packages install but never
                    start. Per ADR 0007 this convergence belongs in Ansible
                    (no clean provider resource models "started"). Remove this
                    subcommand once the provider fixes Run; until then it's the
                    only path to a started package after `tofu apply`.
  ntp               SYNO.Core.Region.NTP v1 set — the NTP client (enable + server),
                    then a forced `sync`. Resolves the old "SET path uncertain"
                    TODO: the API was identified from DSM's own failure logs
                    (`synowebapi_SYNO.Core.Region.NTP_1_status`) and confirmed
                    read-only on e4e-nas 2026-08-10 —
                      SYNO.API.Info query  -> SYNO.Core.Region.NTP, v1..3, entry.cgi
                      methods              -> get / set / sync / status / listzone /
                                              setzone / ensure_ntp_sync_and_enable
                      GET data             -> {enable_ntp: "ntp", server: "...",
                                               timezone: "Pacific", date/hour/
                                               minute/second/now/timestamp}
                    Param names mirror the GET: the symbol table in
                    lib/SYNO.Core.Region.so contains `server` and `enable_ntp`
                    but NO `ntp_server`.
"""

import argparse
import json
import os
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SYNOPKG = "/usr/syno/bin/synopkg"


def _exec(api, *params):
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params], capture_output=True, text=True)
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _args_from(data):
    args = []
    for key, val in data.items():
        if val is None:
            continue
        if isinstance(val, bool):
            val = "true" if val else "false"
        elif isinstance(val, (dict, list)):
            val = json.dumps(val)
        elif isinstance(val, str):
            # synowebapi --exec parses each `key=value` as JSON. Bare
            # strings like `132.239.17.1` are interpreted as malformed
            # floats (synowebapi truncates to `132.239` and SET returns
            # err 4302). JSON-quote so DSM gets the exact string back.
            # Validated 2026-06-01 against e4e-nas: without quoting,
            # `gateway=132.239.17.1` → SET payload had gateway:132.239
            # → 4302; with quoting, the SET lands cleanly.
            val = json.dumps(val)
        args.append("{}={}".format(key, val))
    return args


def _result(drift, check, apply_fn):
    if not drift:
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


def apply_full(api, version, desired, check):
    current = _exec(api, "version=%d" % version, "method=get")["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % version, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def _pkg_is_installed(name):
    """Return True iff the package is installed (DSM creates `/var/packages/<name>`
    when a package's spk is installed; absent if uninstalled or never installed).
    Used to skip-with-warning instead of fail when a desired package isn't
    installed — terraform `synology_core_package` owns presence."""
    return os.path.isdir(os.path.join("/var/packages", name))


def _pkg_is_on(name):
    """Return True iff `synopkg is_onoff <name>` reports the package as on.
    Exit code semantics: 0 = on, non-zero = off / missing. Callers that need
    to disambiguate missing-vs-stopped should compose this with
    `_pkg_is_installed`."""
    out = subprocess.run([SYNOPKG, "is_onoff", name], capture_output=True, text=True)
    return out.returncode == 0


def do_package_state(a):
    """Ensure each package in --packages is started.

    WORKAROUND (see module docstring): the Terraform `synology_core_package`
    resource accepts `run=true` but the upstream go-synology library drops
    that field on the wire, leaving packages installed-but-stopped. We
    converge here with `synopkg start <pkg>`.

    Idempotent: probes `synopkg is_onoff <pkg>`, only `start`s the ones that
    aren't on. No-op if every listed package is already running.

    Bootstrap-tolerant: if a desired package isn't installed at all (i.e.
    terraform hasn't created it yet), warn on stderr + skip rather than fail
    — the role is meant to run AFTER the terraform install, but a fresh box
    where ansible runs first shouldn't be a hard error. The operator sees the
    warning and knows to run `tofu apply` (or the missing package's spec
    entry is a typo)."""
    try:
        desired = json.loads(a.packages)
    except json.JSONDecodeError as e:
        raise SystemExit("--packages must be valid JSON (got error: %s)" % e)
    if not isinstance(desired, list) or not all(isinstance(p, str) for p in desired):
        raise SystemExit("--packages must be a JSON array of package names")

    # Three-way split: missing (warn+skip), installed-but-off (drift), on (no-op).
    missing = [p for p in desired if not _pkg_is_installed(p)]
    drift = [p for p in desired if p not in missing and not _pkg_is_on(p)]
    for p in missing:
        sys.stderr.write(
            "WARN: package %r is not installed (no /var/packages/%s) — "
            "skipping. Install via terraform `synology_core_package` first.\n" % (p, p)
        )

    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps({"start": drift}, sort_keys=True))
        return 0
    failed = []
    for p in drift:
        r = subprocess.run([SYNOPKG, "start", p], capture_output=True, text=True)
        # synopkg start exits 0 + emits a JSON status line; non-zero means real failure.
        if r.returncode != 0 or not _pkg_is_on(p):
            failed.append(
                {"package": p, "stderr": r.stderr.strip()[:200], "stdout": r.stdout.strip()[:200]}
            )
    if failed:
        print("FAIL " + json.dumps(failed))
        return 1
    print("CHANGED " + json.dumps({"started": drift}, sort_keys=True))
    return 0


def do_package_defaults(a):
    """Set the DSM Package Center "default install volume".

    The `synology` Terraform provider's `synology_core_package` resource calls
    `SYNO.Core.Package.Setting.get` and reads `default_vol` from the response
    (see synology-community/go-synology pkg/api/core/client.go
    `PackageInstallCompound` → returns "default volume empty" if unset). On a
    fresh DSM Package Center has never been opened, so the field is empty —
    blocking any tofu-driven package install.

    Param shape (validated 2026-06-02 on DSM 7.3 e4e-nas):
      synowebapi --exec api=SYNO.Core.Package.Setting version=1 method=set \\
        default_vol="/volume1"
    NOT `default_install_vol` (the synoinfo.conf key — distinct, ignored by
    this API path) and NOT `volume`/`vol` (silently no-op, GET unchanged).
    """
    desired = {"default_vol": a.install_volume}
    get_res = _exec("SYNO.Core.Package.Setting", "version=1", "method=get")
    if not get_res.get("success"):
        # Auth/session timeout, permission denied, API rename, etc. — surface
        # structured FAIL with exit code 1 instead of letting `["data"]` raise
        # KeyError + a traceback (which Ansible would re-wrap unhelpfully).
        print(
            "FAIL "
            + json.dumps({"reason": "SYNO.Core.Package.Setting GET failed", "response": get_res})
        )
        return 1
    current = get_res["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }

    def apply():
        return _exec("SYNO.Core.Package.Setting", "version=1", "method=set", *_args_from(desired))

    return _result(drift, a.check, apply)


# Clock-VALUED keys in the NTP GET response. They describe the clock at the
# moment of the GET, not configuration, and must NEVER be echoed back into a SET:
# doing so would ask DSM to set the time to an already-stale reading — the manual
# time-setting path. DSM keeps those separate itself (the library exports
# SYNONtpSet AND a distinct SYNONtpSetWithModifiedTime), which is the evidence
# that a plain config set neither needs nor wants these fields.
_NTP_CLOCK_KEYS = ("date", "hour", "minute", "second", "now", "timestamp")

# GET reports `enable_ntp` as a MODE STRING ("ntp"), not a boolean — it selects
# how the clock is set, and the counterpart value (manual time) is unverified.
_NTP_MODE_ENABLED = "ntp"


def do_ntp(a):
    """Converge the DSM NTP client: enable it and point it at --server.

    WHY THIS EXISTS: nothing managed DSM's time source, and the drift was
    invisible until measured. e4e-nas's AD join had pointed it at the domain
    controller (correct AD behavior — in AD the DC is the domain clock), but
    krg-ldap served no NTP at all, so DSM logged
        "There is no sys.peer NTP server." / "Failed to sync time with
         krg-ldap.krg.local [1]" / "Failed to force sync time"
    on every attempt and the appliance free-ran to +40s (~0.57 s/day, ordinary
    crystal drift). The fix has two halves: krg-ldap now SERVES time
    (nix/modules/time.nix `krg.time.server.enable` + udp/123 through both
    firewall layers), and this subcommand makes the client side declarative.

    SET PAYLOAD: the GET response minus `_NTP_CLOCK_KEYS`, with the desired keys
    merged over it. Full-object rather than partial because sibling DSM APIs in
    this role (SMB/NFS) reject partial sets with err 2001, and there is no cost
    to sending the config fields back unchanged — but the clock fields are
    filtered out first, so a config write can never step the clock.

    TIMEZONE IS DELIBERATELY NOT MANAGED HERE. DSM names zones in its own
    namespace ("Pacific"), not IANA ("America/Los_Angeles" as the spec records),
    so converging it needs the listzone/setzone mapping — a separate surface. The
    live value is already correct, and it round-trips untouched through the
    payload above. Getting a timezone wrong shifts the clock by HOURS, which is
    far worse than the drift being fixed here; that trade is not worth taking on
    as a side effect of an NTP change.
    """
    if not _bool(a.enabled):
        # The disabled value of `enable_ntp` is unverified (GET only ever
        # returned "ntp"), and guessing wrong risks putting DSM into
        # manual-time mode — strictly worse than the drift we're fixing. An AD
        # member should never have NTP off anyway (Kerberos rejects >5 min skew).
        raise SystemExit(
            "ntp: disabling NTP is not supported — the DSM `enable_ntp` value for "
            "'off' is unverified and manual-time mode would be worse than drift. "
            "Set `ntp.enabled: true` in spec/e4e-nas/dsm-system.yml, or drop the "
            "task if this box genuinely must not sync."
        )

    desired = {"enable_ntp": _NTP_MODE_ENABLED, "server": a.server}
    get_res = _exec("SYNO.Core.Region.NTP", "version=1", "method=get")
    if not get_res.get("success"):
        print(
            "FAIL " + json.dumps({"reason": "SYNO.Core.Region.NTP GET failed", "response": get_res})
        )
        return 1
    current = get_res["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }

    def apply():
        payload = {k: v for k, v in current.items() if k not in _NTP_CLOCK_KEYS}
        payload.update(desired)
        return _exec("SYNO.Core.Region.NTP", "version=1", "method=set", *_args_from(payload))

    rc = _result(drift, a.check, apply)

    # Force a sync even when the config was already correct. DSM only runs
    # ntpdate DAILY (`ntpdate_period="daily"`), so a converged config on its own
    # would leave a drifted clock drifted for up to another 24h — and the common
    # case here is exactly that: the server value was already right, it was the
    # SERVER that wasn't answering. This is the appliance equivalent of
    # `chronyc makestep`, and it is what actually closes the +40s.
    #
    # Best-effort by design: a failed sync means the time source is unreachable
    # right now, which is worth SAYING but is not a config-convergence failure.
    # Hard-failing here would take the whole NAS play red on a transient blip,
    # and DSM retries daily regardless. The warning carries the DSM error text so
    # a genuinely dead time source is still visible in the task output.
    if rc == 0 and not a.check:
        sync = _exec("SYNO.Core.Region.NTP", "version=1", "method=sync")
        if not sync.get("success"):
            sys.stderr.write(
                "WARN: NTP config is converged but the forced sync FAILED against "
                "%r — the time source is not answering (check that the DC serves "
                "udp/123 and that both firewall layers allow it). DSM response: "
                "%s\n" % (a.server, json.dumps(sync))
            )
    return rc


def do_network(a):
    desired = {}
    if a.hostname is not None:
        # DSM's SYNO.Core.Network field is `server_name`, not `hostname`.
        # Setting `hostname` is silently dropped on older DSM and outright
        # errors 4302 on DSM 7.3 (validated post-cable-swap 2026-05-31 —
        # GET returns `server_name`, SET rejects unknown fields).
        desired["server_name"] = a.hostname
    if a.gateway is not None:
        desired["gateway"] = a.gateway
    if a.dns_primary is not None:
        desired["dns_primary"] = a.dns_primary
    if a.dns_secondary is not None:
        desired["dns_secondary"] = a.dns_secondary
    if a.dns_manual is not None:
        desired["dns_manual"] = _bool(a.dns_manual)
    if a.ipv4_first is not None:
        desired["ipv4_first"] = _bool(a.ipv4_first)
    return apply_full("SYNO.Core.Network", 2, desired, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    n = sub.add_parser("network")
    n.add_argument("--hostname")
    n.add_argument("--gateway")
    n.add_argument("--dns-primary", dest="dns_primary")
    n.add_argument("--dns-secondary", dest="dns_secondary")
    n.add_argument("--dns-manual", dest="dns_manual")
    n.add_argument("--ipv4-first", dest="ipv4_first")
    n.add_argument("--check", action="store_true")
    n.set_defaults(func=do_network)

    p = sub.add_parser(
        "package-defaults",
        help="Set Package Center default install volume (Terraform provider prerequisite)",
    )
    p.add_argument(
        "--install-volume",
        dest="install_volume",
        required=True,
        help="Mount path, e.g. /volume1 — matches DSM's volume_list mount_point",
    )
    p.add_argument("--check", action="store_true")
    p.set_defaults(func=do_package_defaults)

    s = sub.add_parser(
        "package-state",
        help="Ensure named packages are started (workaround for upstream provider Run-field bug)",
    )
    s.add_argument(
        "--packages", required=True, help='JSON array of package names, e.g. ["ContainerManager"]'
    )
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_package_state)

    t = sub.add_parser(
        "ntp",
        help="Point the DSM NTP client at a server and force a sync (SYNO.Core.Region.NTP v1)",
    )
    t.add_argument(
        "--server",
        required=True,
        help="NTP server, e.g. krg-ldap.krg.local (the AD DC is the domain time authority)",
    )
    t.add_argument(
        "--enabled",
        default="true",
        help="Must be true; see do_ntp for why disabling is not supported",
    )
    t.add_argument("--check", action="store_true")
    t.set_defaults(func=do_ntp)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
