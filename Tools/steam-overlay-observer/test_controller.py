"""Run only in the cloud workflow, against the C ABI fixture's actual binary stats."""
import ctypes as C
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import observer

class ControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = Path(os.environ['OBS_FIXTURE']).read_bytes()
        cls.cpp_data = Path(os.environ['OBS_CPP_FIXTURE']).read_bytes()

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
            for name in observer.payloads_for('capi'):
                (directory / name).write_bytes(name.encode())
            state = {'schema': 1, 'directory': str(directory), 'payload_sha256': {
                name: observer.digest(directory / name) for name in observer.payloads_for('capi')}}
            (directory / 'session.json').write_text(json.dumps(state))
            config = directory / 'observer.cfg'
            config.write_text(observer.windows_path(directory) + '\n')
            self.assertEqual(observer.session_at(directory)[0], directory)
            config.write_text('Z:\\different-session\n')
            with self.assertRaises(RuntimeError):
                observer.session_at(directory)
            config.write_text(observer.windows_path(directory) + '\n')
            (directory / observer.KINDS['capi']['dll']).write_bytes(b'changed')
            with self.assertRaises(RuntimeError):
                observer.session_at(directory)

    def test_cpp_fixture_layout_native_identity_and_exact_forward_counts(self):
        s = observer.decode(self.cpp_data, 'cpp')
        self.assertEqual(s['kind'], 'cpp')
        self.assertEqual(s['counters']['cpu_entries'], 4003)
        self.assertEqual(s['counters']['gpu_entries'], 4002)
        self.assertEqual(s['counters']['missing_original'], 0)
        self.assertEqual(s['counters']['native_id_unreadable'], 2)
        self.assertEqual(s['counters']['records_dropped'], 1)
        self.assertEqual(s['counters']['slot_installed'], 2)
        self.assertEqual(s['counters']['slot_already'], 2)
        self.assertEqual(s['painters'][0]['native_browser_id'], 262146)
        self.assertEqual(s['painters'][0]['identity_valid'], 1)
        self.assertEqual(s['painters'][0]['last_width'], 3024)
        self.assertEqual(s['painters'][0]['last_height'], 1964)
        self.assertEqual(s['painters'][0]['cpu_entries'], 4001)
        self.assertEqual(s['painters'][0]['gpu_entries'], 4001)
        self.assertEqual(s['painters'][1]['identity_valid'], 0)
        self.assertNotIn('cef_id', s['painters'][0])
        self.assertEqual([v['slot_rva'] for v in s['slots']], [0x4a0ab0, 0x4a0ab8])
        self.assertEqual([v['expected_rva'] for v in s['slots']], [0x11a040, 0x119cb0])

    def test_cpp_rejects_mixed_kind_torn_and_over_capacity_stats(self):
        for data, kind in ((self.cpp_data, 'capi'), (self.data, 'cpp'),
                           (self.cpp_data[:-1], 'cpp')):
            with self.assertRaises(RuntimeError):
                observer.decode(data, kind)
        for field, value in (('schema', 99), ('sequence', 1), ('slot_count', 3), ('painter_count', 129)):
            s = observer.CppStats.from_buffer_copy(self.cpp_data)
            setattr(s, field, value)
            with self.assertRaises(RuntimeError):
                observer.decode(bytes(s))

    def test_cpp_session_can_be_prepared_and_attached_without_a_steam_restart(self):
        with tempfile.TemporaryDirectory(prefix='sevo-overlay-build-', dir='/private/tmp') as temporary:
            resources = Path(temporary)
            for name in observer.PAYLOADS:
                (resources / name).write_bytes(name.encode())
            manifest = {'schema': 1, 'source': 'cloud-source', 'cef_sha256': observer.CEF_SHA,
                        'helper_sha256': observer.HELPER_SHA,
                        'payload_sha256': {name: observer.digest(resources / name) for name in observer.PAYLOADS}}
            (resources / 'manifest.json').write_text(json.dumps(manifest))
            steam = resources / 'Steam'
            cef = steam / 'bin/cef/cef.win64'
            real_digest = observer.digest
            def fixture_digest(path):
                if path == cef / 'libcef.dll':
                    return observer.CEF_SHA
                if path == cef / 'steamwebhelper.exe':
                    return observer.HELPER_SHA
                return real_digest(path)
            def run(command, **kwargs):
                self.assertEqual(command[:3], [observer.CLI, 'run', '--wait'])
                directory = Path(command[3]).parent
                self.assertEqual(Path(command[3]).name, observer.ATTACHER)
                self.assertEqual(command[5], observer.windows_path(directory / observer.KINDS['cpp']['dll']))
                self.assertFalse((directory / observer.KINDS['capi']['dll']).exists())
                output = directory / 'attach-result.json'
                output.write_text(json.dumps({'version': 1, 'matched': 1, 'loaded': 1,
                                             'results': [{'status': 'loaded'}]}))
                self.created_session = directory
                return mock.Mock(returncode=0)
            self.created_session = None
            try:
                with mock.patch.object(observer, 'digest', side_effect=fixture_digest), \
                     mock.patch.object(observer.subprocess, 'check_output', return_value=b'{"client":"running"}') as status, \
                     mock.patch.object(observer.subprocess, 'run', side_effect=run), \
                     mock.patch('builtins.print'):
                    self.assertEqual(observer.attach(resources, steam, None, 'cpp'), 0)
                    directory, state = observer.session_at(self.created_session, 'cpp')
                    self.assertEqual(state['kind'], 'cpp')
                    self.assertEqual(status.call_args.args[0], [observer.CLI, 'status', '--json'])
                    with self.assertRaises(RuntimeError):
                        observer.session_at(directory, 'capi')
                    self.assertEqual(observer.attach(resources, steam, directory, 'cpp'), 0)
                    self.assertEqual(status.call_count, 2)
                    (directory / 'cpp-observer.cfg').write_text('Z:\\different-session\n')
                    with self.assertRaises(RuntimeError):
                        observer.session_at(directory)
            finally:
                if self.created_session:
                    import shutil
                    shutil.rmtree(self.created_session)

if __name__ == '__main__':
    unittest.main(verbosity=2)
