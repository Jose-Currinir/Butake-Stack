"""Sign catalog.json of the PHP runtimes and verify the signature; never publish.

The signature is ECDSA P-256 over SHA-256 (DER, what `openssl dgst -sha256 -sign` writes) and goes
in catalog.json.sig next to the catalog. The engine trusts one public key, the constant
CATALOG_PUBLIC_KEY in engine/src/runtimes/languages/php.rs; the signature is checked against that
key before the script ends, so a catalog signed with another key is never left behind.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

OPENSSL = "/usr/bin/openssl"
DEFAULT_KEY = "~/.credenciales/firma-catalogo-php/catalog-signing.pem"
ENGINE_SOURCE = Path(__file__).resolve().parents[2] / "engine/src/runtimes/languages/php.rs"


def engine_public_key():
    """The X9.63 public key (hex) the engine trusts."""
    match = re.search(r'const CATALOG_PUBLIC_KEY: &str =\s*"([0-9a-f]{130})";', ENGINE_SOURCE.read_text())
    if not match:
        raise RuntimeError("engine_public_key_not_found")
    return match.group(1)


def key_path():
    return Path(os.environ.get("STACK_CATALOG_SIGNING_KEY") or DEFAULT_KEY).expanduser()


def run(arguments, **options):
    # The private key is only ever passed to openssl by path.
    return subprocess.run([OPENSSL] + arguments, check=True, capture_output=True, **options).stdout


def public_key_hex(private_key):
    spki = run(["ec", "-in", str(private_key), "-pubout", "-outform", "DER"])
    return spki[-65:].hex()


def verify_signature(catalog, signature, public_key_hex_value):
    """Raises unless `signature` is a valid signature of `catalog` by the given X9.63 public key."""
    point = bytes.fromhex(public_key_hex_value)
    if len(point) != 65 or point[0] != 4:
        raise RuntimeError("invalid_public_key")
    # SPKI header of an uncompressed P-256 key (id-ecPublicKey, prime256v1, 66-byte bit string).
    header = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
    with tempfile.TemporaryDirectory() as folder:
        public = Path(folder) / "public.der"
        public.write_bytes(header + point)
        try:
            run(["dgst", "-sha256", "-verify", str(public), "-keyform", "DER", "-signature", str(signature), str(catalog)])
        except subprocess.CalledProcessError:
            raise RuntimeError("catalog_signature_invalid")


def sign_catalog(catalog, private_key=None, expected_public_key=None):
    """Writes catalog.json.sig next to `catalog` and verifies it with the engine's public key."""
    catalog = Path(catalog).resolve(strict=True)
    private_key = Path(private_key) if private_key else key_path()
    if not private_key.is_file():
        raise RuntimeError("signing_key_missing: " + str(private_key))
    signature = catalog.with_name(catalog.name + ".sig")
    descriptor, temporary = tempfile.mkstemp(prefix=".sig-", dir=catalog.parent)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(run(["dgst", "-sha256", "-sign", str(private_key), str(catalog)]))
        expected = expected_public_key or engine_public_key()
        if public_key_hex(private_key) != expected:
            raise RuntimeError("signing_key_is_not_the_engine_key")
        verify_signature(catalog, temporary, expected)
        os.replace(temporary, signature)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return signature


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("catalog", type=Path)
    arguments = parser.parse_args()
    print(sign_catalog(arguments.catalog))
