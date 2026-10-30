import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ioc_scan", Path(__file__).with_name("scan.py"))
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class ScanTests(unittest.TestCase):
    def test_detects_key_without_exposing_contents(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".ssh"
            path.mkdir()
            (path / "authorized_keys").write_text(
                "ssh-ed25519 " + scanner.KEY + " renamed-comment\n"
            )
            report = scanner.scan([tmp], system=False)
            self.assertIn("attacker_key", [f["indicator"] for f in report["findings"]])
            self.assertNotIn(scanner.KEY, str(report))

    def test_redirected_remote_extension_and_persistence(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as local:
            home, remote = Path(tmp), Path(local)
            (home / ".vscode-server").symlink_to(remote, target_is_directory=True)
            ext = remote / "extensions/anthropic.claude-code-2.1.313"
            ext.mkdir(parents=True)
            (ext / "package.json").write_text('{"publisher":"Anthropic","version":"2.1.313"}')
            (ext / "extension.js").write_text('connect("' + scanner.IP + '")')
            (home / ".config").mkdir()
            (home / ".config/.smt").write_text("test")
            report = scanner.scan([home], system=False)
            indicators = {f["indicator"] for f in report["findings"]}
            self.assertTrue(
                {"persistence_path", "c2_ip", "reported_version_requires_provenance_check"}
                <= indicators
            )

    def test_clean_older_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            ext = Path(tmp) / ".vscode/extensions/anthropic.claude-code-2.1.312"
            ext.mkdir(parents=True)
            (ext / "package.json").write_text('{"version":"2.1.312"}')
            (ext / "extension.js").write_text("legitimate bundle")
            self.assertEqual(scanner.scan([tmp], system=False)["findings"], [])


if __name__ == "__main__":
    unittest.main()
