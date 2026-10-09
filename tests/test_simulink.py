import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import worker


class SimulinkProtocolTests(unittest.TestCase):
    def test_model_explanation_cannot_modify(self):
        worker.validate_response({'explanation': 'Gain scales the input.', 'replacement': ''}, 'sim_explain')
        with self.assertRaises(worker.RequestError):
            worker.validate_response({'explanation': '', 'replacement': 'set_param(...)'}, 'sim_explain')

    def test_supported_structured_operations(self):
        operations = [
            {'op': 'add', 'path': 'G', 'kind': 'Gain', 'position': [10, 20, 40, 60]},
            {'op': 'set', 'path': 'G', 'parameter': 'Gain', 'value': '2'},
            {'op': 'connect', 'source': 'Input', 'source_port': 1, 'target': 'G', 'target_port': 1},
            {'op': 'disconnect', 'source': 'Input', 'source_port': 1, 'target': 'G', 'target_port': 1},
            {'op': 'function', 'path': 'Function', 'code': 'function y=fcn(u)\ny=u;\nend'},
        ]
        worker.validate_response({'explanation': 'Preview only', 'replacement': json.dumps({'operations': operations})}, 'sim_edit')

    def test_raw_commands_unknown_ops_and_invalid_ports_rejected(self):
        values = ['set_param(gcs,...)', '{}', json.dumps({'operations': []}),
                  json.dumps({'operations': [{'op': 'eval', 'code': 'delete_system(...)'}]}),
                  json.dumps({'operations': [{'op': 'connect', 'source': 'A', 'source_port': True, 'target': 'B', 'target_port': 1}]}),
                  json.dumps({'operations': [{'op': 'add', 'path': 'A', 'kind': 'Gain', 'position': [0, 0, -1, 5]}]})]
        for value in values:
            with self.subTest(value=value), self.assertRaises(worker.RequestError):
                worker.validate_simulink_plan(value)

    def test_new_modes_and_history_accepted(self):
        for mode in ('sim_explain', 'sim_edit', 'sim_function'):
            request = {'request_id': 'sim_1', 'question': 'Explain', 'code': '{"model":"test"}', 'mode': mode, 'model': 'test',
                       'history': [{'question': 'old', 'mode': mode, 'explanation': '', 'replacement': ''}]}
            worker.validate_request(request)


if __name__ == '__main__':
    unittest.main()
