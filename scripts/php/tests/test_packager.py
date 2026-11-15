import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / "package_php.py"
spec = importlib.util.spec_from_file_location("packager", source)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagerTests(unittest.TestCase):
    def fixture(self, root):
        runtime = root / "runtime"
        (runtime / "bin").mkdir(parents=True)
        hashes = {}
        for name in ["bin/php", "bin/php-fpm", "cacert.pem", "composer.phar"]:
            (runtime / name).write_bytes(name.encode())
            hashes[name] = hashlib.sha256(name.encode()).hexdigest()
        manifest = {"series": "8.2", "version": "8.2.35", "architecture": "arm64", "minimum_macos": "14.0", "spc_version": "2.8.5", "sha256": hashes}
        (runtime / "manifest.json").write_text(json.dumps(manifest))
        (runtime / "licenses").mkdir()
        (runtime / "licenses/NOTICE").write_text("Third-party notices remain intact.\n")
        return runtime

    def test_deterministic_package_and_local_catalog(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = self.fixture(root)
            with patch.object(packager.subprocess, "run"), patch("builtins.print"):
                packager.package(runtime, root / "output")
                artifact = root / "output/php-8.2.35-macos-arm64.tar.gz"
                first = packager.digest(artifact)
                packager.package(runtime, root / "output")
                self.assertEqual(first, packager.digest(artifact))
            catalog = json.loads((root / "output/catalog.json").read_text())
            self.assertEqual(len(catalog["entries"]), 1)
            self.assertEqual(catalog["entries"][0]["sha256"], first)
            self.assertIsNone(catalog["entries"][0]["download_url"])
            with tarfile.open(artifact) as archive:
                self.assertIn("licenses/NOTICE", archive.getnames())
                for member in archive:
                    self.assertEqual(member.mtime, 0)
                    self.assertEqual(member.uid, 0)
                    self.assertTrue(member.isfile())

    def test_tampered_runtime_is_rejected_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = self.fixture(root)
            (runtime / "bin/php").write_bytes(b"tampered")
            with patch.object(packager.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "hash_mismatch"):
                    packager.package(runtime, root / "output")
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
