"""Check effective invitation credentials without emitting Docker environment data."""

import json
from pathlib import Path
import subprocess
import sys
import time


KEYS = ("AUTHENTIK_URL", "AUTHENTIK_BRAND_ID", "AUTHENTIK_API_TOKEN")
NODE_CHECK = r"""
(async () => {
  // Read-only checks. Do not create production invitations during deployment.
  const env = process.env;
  const app = await fetch(`http://127.0.0.1:${env.PORT || '3000'}/collab-manage`, {
    redirect: 'manual', signal: AbortSignal.timeout(5000)
  });
  if (app.status !== 403) throw new Error('Roster revision unavailable');
  const url = new URL(env.AUTHENTIK_URL);
  if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Invalid origin');
  const result = await fetch(new URL(`/api/v3/core/brands/${env.AUTHENTIK_BRAND_ID}/`, url), {
    headers: { Authorization: `Bearer ${env.AUTHENTIK_API_TOKEN}` },
    redirect: 'error', signal: AbortSignal.timeout(10000)
  });
  if (!result.ok) throw new Error('Catalog read denied');
  const catalog = (await result.json()).attributes?.roster_collaborators;
  if (catalog?.flowSlug !== 'krg-collaborator-enrollment' || !catalog.flow ||
      !Array.isArray(catalog.tenants) || !catalog.tenants.length) throw new Error('Catalog missing');
})().catch(() => { process.exitCode = 1; });
"""


def expected_values(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        key, separator, value = line.strip().partition("=")
        if separator and key in KEYS:
            values[key] = value
    if any(not values.get(key) for key in KEYS):
        raise ValueError("Roster invitation secret is not populated after Authentik apply")
    return values


def runtime_matches(expected, inspection):
    if len(inspection) != 1 or not inspection[0].get("State", {}).get("Running"):
        return False
    actual = dict(
        entry.split("=", 1)
        for entry in inspection[0].get("Config", {}).get("Env", [])
        if "=" in entry
    )
    return all(actual.get(key) == expected[key] for key in KEYS)


def run():
    expected = expected_values("/run/krg/roster/invitations.env")
    # The reload is synchronous, but backend startup may still be in progress.
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        containers = subprocess.run(
            [
                "docker",
                "ps",
                "-q",
                "--filter",
                "label=com.docker.compose.project=e4e-roster",
                "--filter",
                "label=com.docker.compose.service=backend",
            ],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        ).stdout.split()
        if len(containers) == 1:
            # Capture internally: docker inspect includes ALL environment secrets.
            inspection = subprocess.run(
                ["docker", "inspect", containers[0]],
                capture_output=True,
                text=True,
                timeout=10,
                check=True,
            )
            if runtime_matches(expected, json.loads(inspection.stdout)):
                checked = subprocess.run(
                    ["docker", "exec", "-i", containers[0], "node"],
                    input=NODE_CHECK,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                if checked.returncode == 0:
                    print("Roster invitation runtime and Authentik catalog verified.")
                    return
        time.sleep(3)
    raise ValueError(
        "Roster invitation activation failed; check deployed roster revision, env render, and Authentik RBAC"
    )


if __name__ == "__main__":
    try:
        run()
    except Exception:
        # Never print subprocess stdout/stderr or exception data: these may
        # include secrets from Docker inspection or provider response bodies.
        print(
            "ERROR: roster invitation activation failed; check revision, rendered credentials, and Authentik permissions.",
            file=sys.stderr,
        )
        sys.exit(1)
