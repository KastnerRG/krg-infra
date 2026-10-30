#!/usr/bin/env python3
"""Run scan.py over strict, noninteractive SSH. No remote files are written."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys

HOSTS = {
    "fabricant": "krg-admin",
    "waiter": "krg-admin",
    "krg-ldap": "krg-admin",
    "krg-vault": "krg-admin",
    "krg-deploy": "krg-admin",
    "krg-prod": "krg-admin",
    "e4e-prod": "e4e-admin",
    "krg-nat": "krg-admin",
    "kastner-ml": "e4e-admin",
    "e4e-nas": "e4e-admin",
}
SOURCE = Path(__file__).with_name("scan.py").read_bytes()
JUMP = None
KNOWN_HOSTS = None
IDENTITY = str(Path.home() / ".ssh/id_ed25519")
TIMEOUT = 300


def probe(item):
    host, user = item
    argv = [
        "ssh",
        "-i",
        IDENTITY,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ConnectTimeout=8",
        "-o",
        "ServerAliveInterval=5",
        "-o",
        "ServerAliveCountMax=1",
        *(["-J", JUMP] if JUMP else []),
        *(["-o", "UserKnownHostsFile=" + KNOWN_HOSTS] if KNOWN_HOSTS else []),
        user + "@" + host + ".ucsd.edu",
        'p=$(command -v python3); if test -z "$p"; then '
        "for candidate in /nix/store/*-python3-*/bin/python3; do "
        'if test -x "$candidate"; then p=$candidate; break; fi; done; fi; '
        'if test -n "$p"; then sudo -n "$p" -B -; '
        'else echo "No installed Python interpreter" >&2; exit 127; fi',
    ]
    try:
        proc = subprocess.run(
            argv, input=SOURCE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT
        )
        try:
            report = json.loads(proc.stdout)
            if not isinstance(report, dict) or "findings" not in report:
                raise ValueError("Not a scanner report")
            return host, {"status": "scanned", "exit_code": proc.returncode, "report": report}
        except ValueError:
            return host, {
                "status": "unscanned",
                "exit_code": proc.returncode,
                "reason": proc.stderr.decode(errors="replace")[:2000],
            }
    except (OSError, subprocess.TimeoutExpired) as exc:
        return host, {"status": "unscanned", "reason": str(exc)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jump", help="Existing, trusted SSH jump host")
    parser.add_argument("--identity", default=IDENTITY, help="Existing SSH identity file")
    parser.add_argument("--known-hosts", help="Public host keys obtained through a trusted channel")
    parser.add_argument("--hosts", nargs="+", choices=sorted(HOSTS), default=list(HOSTS))
    args = parser.parse_args()
    JUMP = args.jump
    KNOWN_HOSTS = args.known_hosts
    IDENTITY = args.identity
    with ThreadPoolExecutor(max_workers=5) as pool:
        results = dict(pool.map(probe, [(h, HOSTS[h]) for h in args.hosts]))
    print(json.dumps(results, indent=2))
    sys.exit(
        1
        if any(v.get("report", {}).get("findings") for v in results.values())
        else 2
        if any(
            v["status"] != "scanned" or v.get("report", {}).get("coverage_gaps")
            for v in results.values()
        )
        else 0
    )
