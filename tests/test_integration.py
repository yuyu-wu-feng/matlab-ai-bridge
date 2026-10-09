import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('integration_install', Path(__file__).resolve().parents[1] / 'integration/install.py')
integration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integration)


class IntegrationTests(unittest.TestCase):
    def test_install_idempotent_and_uninstall_preserves_script(self):
        original = '% 中文启动设置\r\na=1;\r\n'.encode('utf-8')
        installed = integration.add_block(original, Path('F:/project'))
        self.assertEqual(installed, integration.add_block(installed, Path('F:/project')))
        self.assertEqual(integration.remove_block(installed), original)

    def test_utf16_startup_preserved(self):
        original = b'\xff\xfe' + 'disp("中文");\r\n'.encode('utf-16-le')
        installed = integration.add_block(original, Path('F:/project'))
        self.assertIn('matlab_ai_startup', installed[2:].decode('utf-16-le'))
        self.assertEqual(integration.remove_block(installed), original)

    def test_later_user_changes_are_preserved(self):
        installed = integration.add_block(b'a=1;\n', Path('F:/project')) + b'b=2;\n'
        self.assertEqual(integration.remove_block(installed), b'a=1;\nb=2;\n')

    def test_empty_startup_roundtrip(self):
        self.assertEqual(integration.remove_block(integration.add_block(b'', Path('F:/project'))), b'')


if __name__ == '__main__':
    unittest.main(verbosity=2)
