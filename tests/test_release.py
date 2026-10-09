import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_builder',ROOT/'scripts/build_release.py')
builder=importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)


class ReleaseTests(unittest.TestCase):
    def test_bundle_is_reproducible_and_private_files_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            version=(ROOT/'VERSION').read_text().strip()
            first=builder.build(ROOT,version,Path(directory))
            second=builder.build(ROOT,version,Path(directory))
            self.assertEqual(first['sha256'],second['sha256'])
            with zipfile.ZipFile(first['zip']) as package:
                paths=package.namelist()
                self.assertIn('matlab-ai-bridge/start_ai.m',paths)
                self.assertIn('matlab-ai-bridge/LICENSE',paths)
                for name in paths:
                    self.assertFalse(set(Path(name).parts) & builder.FORBIDDEN_PARTS)
                    self.assertNotEqual(Path(name).name,'config.local.json')
                manifest=package.read('matlab-ai-bridge/MANIFEST.sha256').decode()
                for line in manifest.splitlines():
                    digest,name=line.split('  ',1)
                    self.assertEqual(hashlib.sha256(package.read('matlab-ai-bridge/'+name)).hexdigest(),digest)

    def test_version_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError): builder.build(ROOT,'v99.0.0',Path(directory))
