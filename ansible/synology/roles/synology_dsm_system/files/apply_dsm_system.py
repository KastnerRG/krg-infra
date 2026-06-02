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
  ntp               Reserved — SET path uncertain on this DSM (SYNO.Core.System.Conf
                    or a Region.NTP API not in the captured .libs).
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SYNOPKG = "/usr/syno/bin/synopkg"


def _exec(api, *params):
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params],
                         capture_output=True, text=True)
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
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % version, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def _pkg_is_on(name):
    """Return True iff `synopkg is_onoff <name>` reports the package as on.
    Exit code semantics: 0 = on, non-zero = off / missing. We don't try to
    distinguish missing-vs-stopped here — the Terraform `synology_core_package`
    resource owns presence, this subcommand owns running state."""
    out = subprocess.run([SYNOPKG, "is_onoff", name],
                         capture_output=True, text=True)
    return out.returncode == 0


def do_package_state(a):
    """Ensure each package in --packages is started.

    WORKAROUND (see module docstring): the Terraform `synology_core_package`
    resource accepts `run=true` but the upstream go-synology library drops
    that field on the wire, leaving packages installed-but-stopped. We
    converge here with `synopkg start <pkg>`.

    Idempotent: probes `synopkg is_onoff <pkg>`, only `start`s the ones that
    aren't on. No-op if every listed package is already running.
    """
    desired = json.loads(a.packages)
    if not isinstance(desired, list) or not all(isinstance(p, str) for p in desired):
        raise SystemExit("--packages must be a JSON array of package names")
    drift = [p for p in desired if not _pkg_is_on(p)]
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
            failed.append({"package": p, "stderr": r.stderr.strip()[:200],
                           "stdout": r.stdout.strip()[:200]})
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
    current = _exec("SYNO.Core.Package.Setting", "version=1", "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        return _exec("SYNO.Core.Package.Setting", "version=1", "method=set",
                     *_args_from(desired))

    return _result(drift, a.check, apply)


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

    p = sub.add_parser("package-defaults",
                       help="Set Package Center default install volume (Terraform provider prerequisite)")
    p.add_argument("--install-volume", dest="install_volume", required=True,
                   help="Mount path, e.g. /volume1 — matches DSM's volume_list mount_point")
    p.add_argument("--check", action="store_true")
    p.set_defaults(func=do_package_defaults)

    s = sub.add_parser("package-state",
                       help="Ensure named packages are started (workaround for upstream provider Run-field bug)")
    s.add_argument("--packages", required=True,
                   help='JSON array of package names, e.g. ["ContainerManager"]')
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_package_state)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
