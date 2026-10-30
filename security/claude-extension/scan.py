#!/usr/bin/env python3
"""Read-only IOC triage. JSON contains paths/indicator names, never file contents."""

import argparse
import datetime
import glob
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess

# Incus exec may provide a minimal PATH on NixOS.
os.environ["PATH"] = "/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin:" + os.environ.get(
    "PATH", ""
)

IP = "134.209.82.225"
KEY = "AAAAC3NzaC1lZDI1NTE5AAAAIDdvylCEJ/k2TpezcTfedrkHyFSK9IZ3vmP6vhY4Ss0P"
HASHES = {
    "ecb58cb29078d9646ad1dcdbe51526f2d9cfea06be5fb2ab183e8ecc3ab6bf15",
    "7e0a52885fadee05544a9e99eb18c792bec05900a5e1a66d68f8383decb0e278",
}
MARKERS = {
    IP: "c2_ip",
    KEY: "attacker_key",
    "svc-telemetry": "key_comment",
    ".config/.smt": "persistence_reference",
    "com.apple.sysmond": "launchagent",
}


def scan(homes, system=True):
    findings, gaps, checked, extensions = [], [], set(), []

    def inspect(path, presence=False):
        path = Path(path)
        if not os.path.lexists(str(path)) or str(path) in checked:
            return
        checked.add(str(path))
        if presence:
            findings.append({"path": str(path), "indicator": "persistence_path"})
        try:
            if not path.is_file():
                return
            if path.stat().st_size > 32 * 1024 * 1024:
                gaps.append({"path": str(path), "reason": "over_32MiB"})
                return
            data = path.read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            for marker, name in MARKERS.items():
                if marker.encode() in data:
                    findings.append({"path": str(path), "indicator": name})
            if digest in HASHES:
                findings.append({"path": str(path), "indicator": "known_sha256", "sha256": digest})
        except OSError as exc:
            gaps.append({"path": str(path), "reason": type(exc).__name__})

    def walk_files(root, names=None):
        if not root.exists():
            return

        def error(exc):
            gaps.append({"path": exc.filename, "reason": type(exc).__name__})

        for base, dirs, files in os.walk(str(root), onerror=error):
            # Never traverse symlink trees recursively; explicit IDE roots below follow
            # their root symlink (the fleet redirects remote servers into /local).
            for name in files:
                if names is None or name in names:
                    inspect(Path(base) / name)

    for home in homes:
        home = Path(home)
        try:
            list(home.iterdir())
        except OSError as exc:
            gaps.append({"path": str(home), "reason": type(exc).__name__})
            continue
        for rel in [
            ".config/.smt",
            ".config/.smtk",
            ".config/smt.cmd",
            ".config/smtk",
            "Library/LaunchAgents/com.apple.sysmond.plist",
            "AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/sysmon.cmd",
        ]:
            inspect(home / rel, presence=True)
        walk_files(home / ".ssh")
        walk_files(home / ".config/systemd/user")
        for rel in [".profile", ".bashrc", ".zshrc"]:
            inspect(home / rel)
        for rel in [
            ".vscode/extensions",
            ".vscode-insiders/extensions",
            ".vscode-server/extensions",
            ".vscode-server-insiders/extensions",
            ".cursor/extensions",
            ".cursor-server/extensions",
            ".vscode-oss/extensions",
            ".vscodium-server/extensions",
            ".windsurf/extensions",
            ".windsurf-server/extensions",
        ]:
            root = home / rel
            if not root.exists():
                continue
            try:
                children = list(root.iterdir())
            except OSError as exc:
                gaps.append({"path": str(root), "reason": type(exc).__name__})
                continue
            for ext in children:
                manifest = ext / "package.json"
                if "claude" not in ext.name.lower():
                    continue
                try:
                    meta = json.loads(manifest.read_text())
                    extensions.append(
                        {
                            "path": str(ext),
                            "publisher": meta.get("publisher"),
                            "version": meta.get("version"),
                        }
                    )
                    if meta.get("version") == "2.1.313":
                        findings.append(
                            {
                                "path": str(ext),
                                "indicator": "reported_version_requires_provenance_check",
                            }
                        )
                    walk_files(ext, {"extension.js", "package.json"})
                except (OSError, ValueError) as exc:
                    gaps.append({"path": str(manifest), "reason": type(exc).__name__})
        for rel in [".config/Code/logs", ".config/VSCodium/logs", ".vscode-server/data/logs"]:
            walk_files(home / rel)
        for rel in [".config/Code/CachedExtensionVSIXs", ".config/VSCodium/CachedExtensionVSIXs"]:
            root = home / rel
            if root.exists():
                try:
                    for p in root.iterdir():
                        if "claude" in p.name.lower() and "2.1.313" in p.name:
                            findings.append(
                                {"path": str(p), "indicator": "cached_reported_version"}
                            )
                except OSError as exc:
                    gaps.append({"path": str(root), "reason": type(exc).__name__})
    if system:
        for root in ["/tmp", "/var/tmp"]:
            for name in glob.glob(root + "/.stk_*"):
                inspect(name, presence=True)
        for root in [
            "/etc/cron.d",
            "/var/spool/cron",
            "/etc/systemd/system",
            "/etc/ssh/authorized_keys.d",
        ]:
            walk_files(Path(root))
        for name in ["/etc/crontab", "/var/log/auth.log", "/var/log/secure"]:
            inspect(name)
        # Do not emit other processes' full command lines or socket listings.
        for argv in [
            ["ps", "-eo", "pid=,ppid=,args="],
            ["ss", "-ntap"],
            [
                "journalctl",
                "--since",
                "2026-10-29",
                "--no-pager",
                "-q",
                "--grep",
                "134[.]209[.]82[.]225|svc-telemetry|AAAAC3NzaC1lZDI1NTE5AAAAIDdvylCEJ",
                "-u",
                "ssh",
                "-u",
                "sshd",
            ],
        ]:
            try:
                proc = subprocess.run(
                    argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45
                )
                no_matches = argv[0] == "journalctl" and proc.returncode == 1 and not proc.stderr
                if (proc.returncode and not no_matches) or proc.stderr:
                    gaps.append({"probe": argv[0], "reason": "failed_or_partial"})
                output = proc.stdout
                if argv[0] == "ps":
                    rows = [line.split(None, 2) for line in output.splitlines()]
                    parents = {int(r[0]): int(r[1]) for r in rows if len(r) == 3}
                    ancestors, pid = set(), os.getpid()
                    while pid and pid not in ancestors:
                        ancestors.add(pid)
                        pid = parents.get(pid, 0)
                    # Our launching shells can contain the scanner source/IOCs.
                    output = b"\n".join(
                        r[2] for r in rows if len(r) == 3 and int(r[0]) not in ancestors
                    )
                for marker, name in MARKERS.items():
                    if marker.encode() in output:
                        findings.append({"probe": argv[0], "indicator": name})
            except (OSError, subprocess.TimeoutExpired) as exc:
                gaps.append({"probe": argv[0], "reason": type(exc).__name__})
    return {
        "host": socket.gethostname(),
        "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "euid": os.geteuid(),
        "homes": [str(p) for p in homes],
        "checked_files": len(checked),
        "extensions": extensions,
        "findings": findings,
        "coverage_gaps": gaps,
        "scope": "Targeted visible Linux/Unix artifacts; not a full forensic clearance. Process/network probes see the execution namespace only.",
    }


def default_homes():
    homes = {Path("/root")}
    for parent in [
        "/home",
        "/local",
        "/srv/nfs/home",
        "/var/services/homes",
        "/volume1/homes",
        "/volume2/homes",
    ]:
        root = Path(parent)
        if root.exists():
            try:
                children = [p for p in root.iterdir() if p.is_dir()]
                homes.update(children)
                # DSM AD homes: @DH-REALM/<bucket>/<user>-<uid>.
                if str(root).endswith("/homes"):
                    for group in children:
                        if group.name.startswith(("@DH-", "@LH-")):
                            try:
                                homes.update(p for p in group.glob("*/*") if p.is_dir())
                            except OSError:
                                homes.add(group)
            except OSError:
                homes.add(root)  # scan records the access failure
    try:
        for line in Path("/etc/passwd").read_text().splitlines():
            parts = line.split(":")
            if (
                len(parts) == 7
                and (int(parts[2]) >= 1000 or parts[0] == "root")
                and Path(parts[5]).is_dir()
            ):
                homes.add(Path(parts[5]))
    except OSError:
        pass
    homes.update(Path(p) for p in glob.glob("/var/lib/*admin*") if Path(p).is_dir())
    return sorted(homes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", action="append")
    args = parser.parse_args()
    result = scan(args.home or default_homes())
    print(json.dumps(result, indent=2))
    raise SystemExit(1 if result["findings"] else 2 if result["coverage_gaps"] else 0)
