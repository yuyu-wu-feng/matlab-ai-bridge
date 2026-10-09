import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import model_catalog as catalog
import worker


class ModelCatalogTests(unittest.TestCase):
    def test_filters_hidden_duplicates_and_nontext(self):
        rows = [{'model': 'visible', 'defaultReasoningEffort': 'medium'},
                {'slug': 'visible'}, {'id': 'hidden', 'hidden': True},
                {'id': 'other', 'visibility': 'hide'}, {'id': 'voice', 'inputModalities': ['audio']},
                {'id': '', 'inputModalities': ['text']}, {'id': 'no-api', 'supported_in_api': False}]
        result = catalog.normalize_models(rows, 'codex')
        self.assertEqual([m['id'] for m in result], ['visible'])
        self.assertEqual(result[0]['effort'], 'medium')

    def test_rpc_pagination_and_no_generation(self):
        class CapturedInput(io.StringIO):
            def close(self):
                self.captured = self.getvalue()
                super().close()
        stdin = CapturedInput()
        messages = [{'id': 1, 'result': {}},
                    {'method': 'some/notification'},
                    {'id': 2, 'result': {'data': [{'model': 'first'}], 'nextCursor': 'page2'}},
                    {'id': 3, 'result': {'data': [{'model': 'second'}], 'nextCursor': None}}]
        process = Mock(stdin=stdin, stdout=io.StringIO('\n'.join(map(json.dumps, messages))))
        process.poll.return_value = 0
        with patch.object(catalog.subprocess, 'Popen', return_value=process):
            rows = catalog.read_rpc_models('codex', '.')
        sent = [json.loads(line) for line in stdin.captured.splitlines()]
        self.assertEqual([m['method'] for m in sent], ['initialize', 'initialized', 'model/list', 'model/list'])
        self.assertEqual(sent[-1]['params']['cursor'], 'page2')
        self.assertEqual(len(rows), 2)

    def test_remote_catalog_and_explicit_custom_model(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(catalog, 'read_rpc_models', return_value=[{'model': 'listed'}]):
                result = catalog.discover({'model': 'custom', 'codex_executable': 'codex'}, directory, directory)
        self.assertEqual(result['source'], 'codex')
        self.assertEqual(result['selected'], 'custom')
        self.assertEqual(result['models'][0]['source'], 'config')
        self.assertEqual(result['models'][1]['id'], 'listed')

    def test_cache_fallback_is_labelled(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'models_cache.json').write_text(json.dumps({'models': [{'slug': 'cached'}]}))
            (path / 'unrelated-provider.json').write_text(json.dumps({'models': [{'slug': 'wrong-provider'}]}))
            with patch.object(catalog, 'read_rpc_models', side_effect=TimeoutError):
                result = catalog.discover({'model': 'configured', 'codex_executable': 'codex'}, path, path)
        self.assertEqual(result['source'], 'cache')
        self.assertTrue(result['warning'])
        self.assertEqual([m['id'] for m in result['models']], ['configured', 'cached'])

    def test_empty_or_corrupt_sources_remain_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'models_cache.json').write_text('{broken')
            with patch.object(catalog, 'read_rpc_models', return_value=[]):
                empty = catalog.discover({'model': '', 'codex_executable': 'codex'}, directory, directory)
                fallback = catalog.discover({'model': 'configured', 'codex_executable': 'codex'}, directory, directory)
        self.assertFalse(empty['ok'])
        self.assertEqual(empty['models'], [])
        self.assertEqual(fallback['source'], 'config')

    def test_selected_model_and_effort_reach_cli(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'CODEX_HOME': directory}):
            command, model = worker.codex_command({'model': 'default', 'codex_executable': 'codex'},
                {'model': 'selected', 'reasoning_effort': 'medium'}, Path(directory), Path(directory) / 'out.json')
        self.assertEqual(model, 'selected')
        self.assertEqual(command[command.index('--model') + 1], 'selected')
        self.assertIn('model_reasoning_effort="medium"', command)


if __name__ == '__main__':
    unittest.main(verbosity=2)
