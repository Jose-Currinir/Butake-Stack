import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / "build_php.py"
spec = importlib.util.spec_from_file_location("builder", source)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BuilderTests(unittest.TestCase):
    def test_managed_directories_reject_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            (root / "logs").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "unsafe_managed_path"):
                builder.private_directory(root, "logs")

    def test_archive_traversal_and_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, symlink in [("../escape", False), ("/escape", False), ("link", True)]:
                archive = root / "test.tar"
                with tarfile.open(archive, "w") as output:
                    member = tarfile.TarInfo(name)
                    if symlink:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "../../escape"
                    else:
                        member.size = 1
                    output.addfile(member, None if symlink else io.BytesIO(b"x"))
                with self.assertRaisesRegex(RuntimeError, "unsafe_archive"):
                    builder.extract(archive, root / "output")
            self.assertFalse((root / "escape").exists())

    def test_mismatch_removes_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "download"
            with patch.object(builder.subprocess, "run", side_effect=lambda *a, **kw: path.write_bytes(b"bad")):
                with self.assertRaisesRegex(RuntimeError, "hash_mismatch"):
                    builder.download({"url": "https://example.test/file", "sha256": "0" * 64}, path, [], {})
            self.assertFalse(path.exists())

    def test_failed_preflight_cleans_workspace(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(builder, "preflight", side_effect=RuntimeError("missing_build_tools")):
                with self.assertRaisesRegex(RuntimeError, "missing_build_tools"):
                    builder.build("8.2", root / "home", root / "build")
            self.assertEqual(list((root / "build").iterdir()), [])
            self.assertTrue((root / "home/logs/php-build-8.2-downloads.json").is_file())


if __name__ == "__main__":
    unittest.main()
