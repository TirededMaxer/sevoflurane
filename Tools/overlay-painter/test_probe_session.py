import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('painter_probe',Path(__file__).with_name('painter_probe.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve()
        self.steam=self.root/'Steam';self.cef=self.steam/'bin/cef/cef.win64';self.cef.mkdir(parents=True)
        self.original=b'original fixture DLL';(self.cef/'libcef.dll').write_bytes(self.original)
        self.resources=self.root/'resources';self.resources.mkdir()
        manifest={'source':'fixture'}
        for name,key in [('sevo-painter.dll','probe_sha256'),('sevo-painter-attach.exe','attach_sha256')]:
            payload=name.encode();(self.resources/name).write_bytes(payload);manifest[key]=hashlib.sha256(payload).hexdigest()
        (self.resources/'probe-manifest.json').write_text(json.dumps(manifest))
        self.state=patch.object(m,'client_state',return_value='running').start()
        patch.object(m,'CEF_SHA',hashlib.sha256(self.original).hexdigest()).start()
        patch.object(m,'__file__',str(self.resources/'painter_probe.py')).start()
        self.loader=patch.object(m.subprocess,'run',return_value=subprocess.CompletedProcess([],0)).start()
        original_mkdtemp=tempfile.mkdtemp
        patch.object(m.tempfile,'mkdtemp',side_effect=lambda **kw:original_mkdtemp(prefix=kw['prefix'],dir=self.root)).start()
    def tearDown(self):
        patch.stopall();self.temp.cleanup()
    def call(self,*args):
        with patch.object(sys,'argv',['painter_probe.py',*map(str,args),'--steam',str(self.steam)]),contextlib.redirect_stdout(io.StringIO()) as out:m.main()
        return json.loads(out.getvalue())
    def session(self):return Path(self.call('attach')['session'])
    def test_attach_and_finish_leave_valve_files_identical(self):
        before={p.relative_to(self.steam):p.read_bytes() for p in self.steam.rglob('*') if p.is_file()}
        session=self.session();self.assertTrue((session/'sevo-painter.dll').exists())
        command=self.loader.call_args.args[0];self.assertIn('steamwebhelper.exe',command[-3])
        self.state.return_value='stopped';self.assertTrue(self.call('finish','--session',session)['finished'])
        self.assertFalse(session.exists())
        after={p.relative_to(self.steam):p.read_bytes() for p in self.steam.rglob('*') if p.is_file()}
        self.assertEqual(before,after)
    def test_unknown_cef_rejected_before_attachment(self):
        (self.cef/'libcef.dll').write_bytes(b'updated')
        with self.assertRaisesRegex(RuntimeError,'CEF changed'):self.call('attach')
        self.loader.assert_not_called();self.assertFalse(list(self.root.glob('sevo-painter-*')))
    def test_loader_failure_preserves_diagnostic_session(self):
        self.loader.return_value=subprocess.CompletedProcess([],1)
        with self.assertRaises(SystemExit):self.call('attach')
        sessions=list(self.root.glob('sevo-painter-*'));self.assertEqual(len(sessions),1)
        self.assertTrue((sessions[0]/'session.json').exists())
        self.assertEqual((self.cef/'libcef.dll').read_bytes(),self.original)
    def test_finish_rejects_live_client(self):
        session=self.session()
        with self.assertRaisesRegex(RuntimeError,'Normally quit'):self.call('finish','--session',session)
        self.assertTrue(session.exists())
    def test_cpu_overlay_paint_required_for_arm(self):
        session=self.session();stats=session/'cef-123.stats'
        stats.write_bytes(struct.pack('<8sII'+'q'*len(m.NAMES),b'SEVOSTA1',2,123,*([0]*len(m.NAMES))))
        self.loader.reset_mock()
        with self.assertRaisesRegex(RuntimeError,'No CPU overlay paint'):self.call('arm','--session',session,'--stats-file',stats)
        self.loader.assert_not_called()
    def test_stats_version_and_size_rejected(self):
        stats=self.root/'bad.stats';stats.write_bytes(b'bad')
        with self.assertRaisesRegex(RuntimeError,'stats size'):m.read_stats(stats)
        stats.write_bytes(struct.pack('<8sII'+'q'*len(m.NAMES),b'SEVOSTA1',1,123,*([0]*len(m.NAMES))))
        with self.assertRaisesRegex(RuntimeError,'stats version'):m.read_stats(stats)

if __name__=='__main__':unittest.main()
