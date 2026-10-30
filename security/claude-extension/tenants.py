#!/usr/bin/env python3
"""Read-only IOC scan of Incus VMs, using verified krg-nat SSH identity."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shlex
import subprocess


def ssh_options(known_hosts):
    return [
        "ssh",
        "-i",
        str(Path.home() / ".ssh/id_ed25519"),
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
        "UserKnownHostsFile=" + known_hosts,
        "krg-admin@krg-nat.ucsd.edu",
    ]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--known-hosts", required=True)
    args = parser.parse_args()
    ssh = ssh_options(args.known_hosts)
    inventory = subprocess.run(
        ssh + ["sudo -n incus list --all-projects --format json"],
        capture_output=True,
        check=True,
        timeout=30,
    )
    instances = json.loads(inventory.stdout)
    source = Path(__file__).with_name("scan.py").read_bytes()
    interpreter = (
        'p=$(command -v python3); if test -z "$p"; then '
        "for candidate in /nix/store/*-python3-*/bin/python3; do "
        'if test -x "$candidate"; then p=$candidate; break; fi; done; fi; '
        'if test -n "$p"; then exec "$p" -B -; else exit 127; fi'
    )

    def probe(vm):
        key = vm.get("project", "default") + "/" + vm["name"]
        if vm["status"] != "Running":
            return key, {"status": "unscanned", "reason": "Instance is not running"}
        command = shlex.join(
            [
                "sudo",
                "-n",
                "incus",
                "exec",
                vm["name"],
                "--project",
                vm.get("project", "default"),
                "--mode=non-interactive",
                "--",
                "sh",
                "-c",
                interpreter,
            ]
        )
        try:
            proc = subprocess.run(ssh + [command], input=source, capture_output=True, timeout=300)
            try:
                report = json.loads(proc.stdout)
                if not isinstance(report, dict) or "findings" not in report:
                    raise ValueError("Not a scanner report")
                return key, {"status": "scanned", "exit_code": proc.returncode, "report": report}
            except ValueError:
                return key, {
                    "status": "unscanned",
                    "reason": proc.stderr.decode(errors="replace")[:2000],
                    "exit_code": proc.returncode,
                }
        except (OSError, subprocess.TimeoutExpired) as exc:
            return key, {"status": "unscanned", "reason": str(exc)}

    with ThreadPoolExecutor(max_workers=3) as pool:
        results = dict(pool.map(probe, instances))
    print(json.dumps(results, indent=2))
    raise SystemExit(
        1
        if any(v.get("report", {}).get("findings") for v in results.values())
        else 2
        if any(
            v["status"] != "scanned" or v.get("report", {}).get("coverage_gaps")
            for v in results.values()
        )
        else 0
    )
