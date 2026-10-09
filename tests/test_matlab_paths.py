import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from matlab_paths import resolve_matlab_root


class MatlabPathTests(unittest.TestCase):
    def test_explicit_path_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='matlab test ') as d:
            root=Path(d); (root/'bin').mkdir(); (root/'bin/matlab.exe').touch()
            self.assertEqual(resolve_matlab_root(d),root)

    def test_invalid_explicit_path_never_silently_selects_other_install(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError): resolve_matlab_root(d)

    def test_environment_path(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ,{'MATLAB_ROOT':d}):
            root=Path(d); (root/'bin').mkdir(); (root/'bin/matlab.exe').touch()
            self.assertEqual(resolve_matlab_root(),root)
