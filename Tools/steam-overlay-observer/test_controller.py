"""Run only in the cloud workflow, against the C ABI fixture's actual binary stats."""
import ctypes as C
import json
import os
from pathlib import Path
import tempfile
import unittest
import observer

class ControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = Path(os.environ['OBS_FIXTURE']).read_bytes()

    def test_c_fixture_layout_identity_and_counters(self):
        s = observer.decode(self.data)
        self.assertEqual(s['counters']['create_calls'], 5)
        self.assertEqual(s['counters']['render_getters'], 6)
        self.assertEqual(s['counters']['unique_handlers'], 2)
        self.assertEqual(s['counters']['cpu_entries'], 4003)
        self.assertEqual(s['counters']['missing_original'], 2)
        self.assertEqual(s['creates'][2]['async_result_signed'], -7)
        self.assertEqual(s['browsers'][0]['cef_id'], 41)
        self.assertEqual(s['browsers'][0]['steam_browser_id'], 262146)
        self.assertEqual(s['browsers'][1]['gpu_entries'], 1)
        self.assertNotIn(b'private non-overlay title', self.data)
        self.assertEqual(s['slots'][-2]['nulls'], 1)
        self.assertEqual(s['slots'][-1]['rejected'], 1)

    def test_rejects_torn_unknown_or_out_of_bounds_stats(self):
        for raw in (b'', self.data[:-1], b'BADMAGIC' + self.data[8:]):
            with self.assertRaises(RuntimeError):
                observer.decode(raw)
        for field, value in (('schema', 99), ('sequence', 1), ('slot_count', 257)):
            s = observer.Stats.from_buffer_copy(self.data)
            setattr(s, field, value)
            with self.assertRaises(RuntimeError):
                observer.decode(bytes(s))

    def test_existing_session_rejects_payload_or_config_replacement(self):
        with tempfile.TemporaryDirectory(prefix='sevo-overlay-observer-', dir='/private/tmp') as temporary:
            directory = Path(temporary).resolve()
            for name in observer.PAYLOADS:
                (directory / name).write_bytes(name.encode())
            state = {'schema': 1, 'directory': str(directory), 'payload_sha256': {
                name: observer.digest(directory / name) for name in observer.PAYLOADS}}
            (directory / 'session.json').write_text(json.dumps(state))
            config = directory / 'observer.cfg'
            config.write_text(observer.windows_path(directory) + '\n')
            self.assertEqual(observer.session_at(directory)[0], directory)
            config.write_text('Z:\\different-session\n')
            with self.assertRaises(RuntimeError):
                observer.session_at(directory)
            config.write_text(observer.windows_path(directory) + '\n')
            (directory / observer.PAYLOADS[0]).write_bytes(b'changed')
            with self.assertRaises(RuntimeError):
                observer.session_at(directory)

if __name__ == '__main__':
    unittest.main(verbosity=2)
