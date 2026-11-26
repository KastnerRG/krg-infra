"""Exercise deploy ordering and failure gates without touching a live service."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "roster_check", ROOT / "nix/hosts/krg-prod/roster-invitations-check.py"
)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        # Models an existing secret, a successful CAS create, concurrent create,
        # and a persistent read/write failure. No secret is printed to stdout.
        executable = self.path / "bao"
        executable.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ['FAKE_ROOT'])
with (root / 'calls').open('a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
present = root / 'present'
mode = os.environ['FAKE_MODE']
if sys.argv[1:3] == ['kv', 'get']:
    sys.exit(0 if present.exists() else 1)
assert sys.argv[1:4] == ['kv', 'put', '-cas=0']
if mode == 'denied': sys.exit(1)
present.write_text('existing-token' if mode == 'race' else 'placeholder')
sys.exit(1 if mode == 'race' else 0)
""")
        executable.chmod(0o755)

    def bootstrap(self, mode):
        return subprocess.run(
            ["bash", str(ROOT / "deploy/ensure-roster-invitation-secret.sh")],
            env={
                **os.environ,
                "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
                "FAKE_ROOT": str(self.path),
                "FAKE_MODE": mode,
            },
            capture_output=True,
            text=True,
        )

    def test_existing_token_is_never_written(self):
        (self.path / "present").write_text("existing-token")
        self.assertEqual(self.bootstrap("existing").returncode, 0)
        self.assertNotIn("put", (self.path / "calls").read_text())
        self.assertEqual((self.path / "present").read_text(), "existing-token")

    def test_first_deploy_seeds_only_a_placeholder(self):
        self.assertEqual(self.bootstrap("new").returncode, 0)
        self.assertEqual((self.path / "present").read_text(), "placeholder")
        self.assertEqual(self.bootstrap("new").returncode, 0)
        self.assertEqual((self.path / "calls").read_text().count("put"), 1)

    def test_concurrent_writer_is_preserved(self):
        self.assertEqual(self.bootstrap("race").returncode, 0)
        self.assertEqual((self.path / "present").read_text(), "existing-token")

    def test_unavailable_openbao_fails_before_nixos(self):
        result = self.bootstrap("denied")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("existing-token", result.stdout + result.stderr)

    def test_required_target_cannot_be_silently_omitted(self):
        result = subprocess.run(
            ["bash", str(ROOT / "deploy/deploy-tofu.sh")],
            env={**os.environ, "TOFU_TARGETS": "", "TOFU_REQUIRED_TARGETS": "secrets"},
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not selected", result.stderr)

    def test_required_authentik_cannot_skip_missing_credentials(self):
        result = subprocess.run(
            ["bash", str(ROOT / "deploy/deploy-tofu.sh")],
            env={
                **os.environ,
                "TOFU_TARGETS": "authentik",
                "TOFU_REQUIRED_TARGETS": "authentik",
                "OPENBAO_ROLE_ID_FILE": str(self.path / "absent"),
                "OPENBAO_SECRET_ID_FILE": str(self.path / "absent"),
                "VAULT_TOKEN": "",
            },
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required target authentik cannot apply", result.stderr)

    def test_failed_secrets_apply_never_runs_bootstrap(self):
        for name in ["role", "secret"]:
            (self.path / name).write_text("local-test-only")
        (self.path / "bao").write_text("""#!/usr/bin/env python3
import os, pathlib, sys
with (pathlib.Path(os.environ['FAKE_ROOT']) / 'bao-calls').open('a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
print('local-test-session')
""")
        (self.path / "tofu").write_text("""#!/usr/bin/env python3
import sys
sys.exit(1 if 'apply' in sys.argv else 0)
""")
        (self.path / "tofu").chmod(0o755)
        result = subprocess.run(
            ["bash", str(ROOT / "deploy/deploy-tofu.sh")],
            env={
                **os.environ,
                "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
                "FAKE_ROOT": str(self.path),
                "TOFU_TARGETS": "secrets",
                "TOFU_REQUIRED_TARGETS": "secrets",
                "TOFU_SECRETS_APPROVE": "test",
                "TOFU_STATE_ROOT": str(self.path / "state"),
                "TOFU_STATE_PASSPHRASE": "local-test-only",
                "OPENBAO_ROLE_ID_FILE": str(self.path / "role"),
                "OPENBAO_SECRET_ID_FILE": str(self.path / "secret"),
            },
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("kv", (self.path / "bao-calls").read_text())


class ApplicationDeployTests(unittest.TestCase):
    def deploy(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            executable = path / "git"
            executable.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ['FAKE_ROOT'])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\\n')
mode = os.environ['FAKE_MODE']
if name == 'git':
    if 'branch' in args: print('other' if mode == 'branch' else 'main')
    if 'status' in args and mode == 'dirty': print(' M tracked-file')
    if 'cat-file' in args and mode == 'unmerged': sys.exit(1)
    if 'merge-base' in args and mode == 'ahead': sys.exit(1)
if name == 'docker' and mode == 'build-failure': sys.exit(1)
""")
            executable.chmod(0o755)
            for name in ["docker", "systemctl"]:
                (path / name).symlink_to(executable)
            result = subprocess.run(
                [
                    "bash",
                    "-euo",
                    "pipefail",
                    str(ROOT / "nix/hosts/krg-prod/deploy-roster-invitations.sh"),
                ],
                env={
                    **os.environ,
                    "PATH": directory + os.pathsep + os.environ["PATH"],
                    "FAKE_ROOT": directory,
                    "FAKE_MODE": mode,
                    "ROSTER_RUNTIME_OVERRIDE": "/immutable/override.yml",
                },
                capture_output=True,
                text=True,
            )
            return result, (path / "calls").read_text()

    def test_dirty_or_wrong_branch_checkout_is_not_updated(self):
        for mode in ["dirty", "branch"]:
            result, calls = self.deploy(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("fetch", calls)
            self.assertNotIn("docker", calls)

    def test_unmerged_or_local_ahead_code_is_not_built(self):
        for mode in ["unmerged", "ahead"]:
            result, calls = self.deploy(mode)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("merge --ff-only", calls)
            self.assertNotIn("docker", calls)

    def test_build_failure_does_not_reload_running_backend(self):
        result, calls = self.deploy("build-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("systemctl", calls)

    def test_fast_forward_and_build_precede_reload(self):
        result, calls = self.deploy("success")
        self.assertEqual(result.returncode, 0)
        self.assertLess(calls.index("merge --ff-only"), calls.index("docker compose"))
        self.assertLess(calls.index("build backend"), calls.index("systemctl reload"))


class RuntimeTests(unittest.TestCase):
    def test_partial_or_blank_render_is_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invitations.env"
            path.write_text("AUTHENTIK_URL=\nAUTHENTIK_BRAND_ID=\nAUTHENTIK_API_TOKEN=\n")
            with self.assertRaises(ValueError):
                check.expected_values(path)

    def test_restart_with_old_environment_is_rejected(self):
        expected = dict(zip(check.KEYS, ("https://auth.example.org", "brand", "rotated-token")))
        old = [
            {
                "State": {"Running": True},
                "Config": {
                    "Env": [
                        "AUTHENTIK_URL=https://auth.example.org",
                        "AUTHENTIK_BRAND_ID=brand",
                        "AUTHENTIK_API_TOKEN=old-token",
                    ]
                },
            }
        ]
        self.assertFalse(check.runtime_matches(expected, old))
        old[0]["Config"]["Env"][-1] = "AUTHENTIK_API_TOKEN=rotated-token"
        self.assertTrue(check.runtime_matches(expected, old))
        old[0]["State"]["Running"] = False
        self.assertFalse(check.runtime_matches(expected, old))

    def test_runtime_check_accepts_recreated_container_and_checks_live_catalog(self):
        expected = dict(zip(check.KEYS, ("https://auth.example.org", "brand", "secret-token")))
        inspect = [
            {
                "State": {"Running": True},
                "Config": {"Env": [key + "=" + value for key, value in expected.items()]},
            }
        ]
        responses = [
            subprocess.CompletedProcess([], 0, "container\n"),
            subprocess.CompletedProcess([], 0, json.dumps(inspect)),
            subprocess.CompletedProcess([], 0),
        ]
        with patch.object(check, "expected_values", return_value=expected), patch.object(
            check.subprocess, "run", side_effect=responses
        ) as run:
            check.run()
        self.assertEqual(
            run.call_args_list[-1].args[0], ["docker", "exec", "-i", "container", "node"]
        )
        self.assertNotIn("secret-token", str(run.call_args_list[-1]))

    def test_live_catalog_failure_never_reports_activation_success(self):
        with patch.object(check, "expected_values", return_value={}), patch.object(
            check.time, "monotonic", side_effect=[0, 61]
        ):
            with self.assertRaises(ValueError):
                check.run()


if __name__ == "__main__":
    unittest.main()
