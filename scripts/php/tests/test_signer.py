import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / "sign_catalog.py"
spec = importlib.util.spec_from_file_location("signer", source)
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


def make_key(folder):
    key = Path(folder) / "key.pem"
    subprocess.run([signer.OPENSSL, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key)],
                   check=True, capture_output=True)
    return key


class SignerTests(unittest.TestCase):
    def test_signs_and_verifies_with_a_temporary_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            # sign_catalog resolves the catalog; on macOS the temporary folder is a link to /private.
            root = Path(temporary).resolve()
            key = make_key(root)
            public = signer.public_key_hex(key)
            catalog = root / "catalog.json"
            catalog.write_text('{"schema_version": 1, "entries": []}\n')
            signature = signer.sign_catalog(catalog, key, public)
            self.assertEqual(signature, root / "catalog.json.sig")
            signer.verify_signature(catalog, signature, public)
            catalog.write_text('{"schema_version": 1, "entries": [{"id": "evil"}]}\n')
            with self.assertRaisesRegex(RuntimeError, "catalog_signature_invalid"):
                signer.verify_signature(catalog, signature, public)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["catalog.json", "catalog.json.sig", "key.pem"])

    def test_refuses_a_key_the_engine_does_not_trust(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = make_key(root)
            catalog = root / "catalog.json"
            catalog.write_text("{}\n")
            with self.assertRaisesRegex(RuntimeError, "signing_key_is_not_the_engine_key"):
                signer.sign_catalog(catalog, key, "04" + "00" * 64)
            self.assertFalse((root / "catalog.json.sig").exists())

    def test_key_path_comes_from_the_environment(self):
        with patch.dict(os.environ, {"STACK_CATALOG_SIGNING_KEY": "/somewhere/key.pem"}):
            self.assertEqual(signer.key_path(), Path("/somewhere/key.pem"))
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(signer.key_path(), Path(signer.DEFAULT_KEY).expanduser())

    def test_missing_key_is_an_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            catalog = Path(temporary) / "catalog.json"
            catalog.write_text("{}\n")
            with self.assertRaisesRegex(RuntimeError, "signing_key_missing"):
                signer.sign_catalog(catalog, Path(temporary) / "none.pem")

    def test_engine_constant_is_found(self):
        self.assertEqual(len(signer.engine_public_key()), 130)


if __name__ == "__main__":
    unittest.main()
