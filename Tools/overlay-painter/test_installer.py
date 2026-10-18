import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('probe_installer',Path(__file__).with_name('install_probe.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.steam=self.root/'Steam';self.cef=self.steam/'bin/cef/cef.win64';self.cef.mkdir(parents=True)
        self.original=b'original fixture DLL';self.proxy=b'cloud fixture proxy'
        (self.cef/'libcef.dll').write_bytes(self.original)
        self.resources=self.root/'resources';self.resources.mkdir()
        (self.resources/'libcef.dll').write_bytes(self.proxy)
        (self.resources/'probe-manifest.json').write_text(json.dumps({'source':'fixture', 'proxy_sha256':hashlib.sha256(self.proxy).hexdigest()}))
        self.patches=[patch.object(m,'CEF_SHA',hashlib.sha256(self.original).hexdigest()),patch.object(m,'__file__',str(self.resources/'install_probe.py')),patch.object(m,'stopped')]
        for p in self.patches:p.start()
        self.directory=None
    def tearDown(self):
        state=self.cef/'sevo-painter-state.json'
        if state.exists():self.directory=Path(json.loads(state.read_text())['directory'])
        if self.directory and self.directory.exists():shutil.rmtree(self.directory)
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def call(self,*args):
        with patch.object(sys,'argv',['install_probe.py',*args,'--steam',str(self.steam)]),contextlib.redirect_stdout(io.StringIO()) as out:m.main()
        return json.loads(out.getvalue())
    def test_roundtrip_retains_original_bytes(self):
        s=self.call('install');self.directory=Path(s['directory'])
        self.assertEqual((self.cef/'libcef.dll').read_bytes(),self.proxy)
        self.assertEqual((self.cef/'sevo_libcef_original.dll').read_bytes(),self.original)
        self.assertTrue(self.call('restore')['restored'])
        self.assertEqual((self.cef/'libcef.dll').read_bytes(),self.original)
        self.assertFalse((self.cef/'sevo-painter-state.json').exists())
    def test_unknown_cef_is_not_replaced(self):
        (self.cef/'libcef.dll').write_bytes(b'new Steam build')
        with self.assertRaisesRegex(RuntimeError,'CEF changed'):self.call('install')
        self.assertEqual((self.cef/'libcef.dll').read_bytes(),b'new Steam build')
    def test_changed_active_file_is_not_overwritten(self):
        self.call('install');(self.cef/'libcef.dll').write_bytes(b'updated while stopped')
        with self.assertRaisesRegex(RuntimeError,'Steam files changed'):self.call('restore')
        self.assertEqual((self.cef/'libcef.dll').read_bytes(),b'updated while stopped')
    def test_partial_install_rolls_back(self):
        original_read=Path.read_bytes;seen=0
        def read(p):
            nonlocal seen
            if p.resolve()==(self.resources/'libcef.dll').resolve():
                seen+=1
                if seen==2:raise OSError('interrupted copy')
            return original_read(p)
        with patch.object(Path,'read_bytes',read),self.assertRaisesRegex(OSError,'interrupted copy'):self.call('install')
        self.assertEqual((self.cef/'libcef.dll').read_bytes(),self.original)
        self.assertFalse((self.cef/'sevo_libcef_original.dll').exists())
    def test_cpu_path_is_required_for_frame_request(self):
        state=self.call('install');self.directory=Path(state['directory'])
        f=self.directory/'cef-123.stats'
        f.write_bytes(struct.pack('<8sII'+'q'*15,b'SEVOSTA1',1,123,*([0]*15)))
        with self.assertRaisesRegex(RuntimeError,'No CPU overlay paint'):self.call('arm','--stats-file',str(f))
    def test_stats_record_is_versioned(self):
        f=self.root/'bad.stats';f.write_bytes(b'bad')
        with self.assertRaisesRegex(RuntimeError,'stats size'):m.read_stats(f)

if __name__=='__main__':unittest.main()
