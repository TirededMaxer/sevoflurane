"""Attach the exact-build painter experiment to running Steam webhelpers; no Valve file writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
CEF_SHA = 'c85bf94462b3c79baeac63823db52d15e116eead71ea414e5d3a112c59e434d3'
CLI = '/Applications/Sevoflurane.app/Contents/Helpers/sevo'
NAMES = ['created_browsers','render_handlers','titles','overlay_browsers','cpu_paints','gpu_paints',
         'overlay_cpu_paints','overlay_gpu_paints','replacement_paints','restored_paints','rejected_frames',
         'last_width','last_height','last_browser','abi_rejected','iat_hooks']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def client_state():return json.loads(subprocess.check_output([CLI,'status','--json']))['client']
def windows_path(path):
    parts=path.resolve().parts
    for i,part in enumerate(parts):
        if len(part)==7 and part.startswith('drive_'):
            return part[-1].upper()+':\\'+'\\'.join(parts[i+1:])
    return 'Z:'+str(path.resolve()).replace('/','\\')
def read_stats(path):
    data=path.read_bytes()
    if len(data)!=16+len(NAMES)*8:raise RuntimeError('Wrong probe stats size')
    magic,version,pid,*counts=struct.unpack('<8sII'+'q'*len(NAMES),data)
    if magic!=b'SEVOSTA1' or version!=2:raise RuntimeError('Wrong probe stats version')
    return {'file':str(path),'pid':pid,**dict(zip(NAMES,counts))}
def checked_session(path):
    if not path:raise RuntimeError('Select the session directory returned by attach')
    path=path.resolve();state=json.loads((path/'session.json').read_text())
    if state['schema']!=2 or Path(state['directory']).resolve()!=path:raise RuntimeError('Wrong probe session')
    return path,state

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['attach','status','arm','finish'])
    p.add_argument('--steam',type=Path,default=Path.home()/'Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam')
    p.add_argument('--session',type=Path);p.add_argument('--stats-file',type=Path)
    args=p.parse_args();resources=Path(__file__).resolve().parent
    if args.action=='attach':
        if client_state()!='running':raise RuntimeError('Start Steam normally before attaching the probe')
        cef=args.steam/'bin/cef/cef.win64';original=cef/'libcef.dll'
        if digest(original)!=CEF_SHA:raise RuntimeError('CEF changed; fresh ABI calibration required')
        manifest=json.loads((resources/'probe-manifest.json').read_text())
        for name,key in [('sevo-painter.dll','probe_sha256'),('sevo-painter-attach.exe','attach_sha256')]:
            if digest(resources/name)!=manifest[key]:raise RuntimeError('Probe payload hash mismatch')
        directory=Path(tempfile.mkdtemp(prefix='sevo-painter-',dir='/private/tmp'));os.chmod(directory,0o700)
        for name in ['sevo-painter.dll','sevo-painter-attach.exe']:shutil.copy2(resources/name,directory/name)
        (directory/'sevo-painter-probe.txt').write_text(windows_path(directory)+'\n')
        state={'schema':2,'directory':str(directory),'source':manifest['source'],'original_cef_sha256':CEF_SHA,'dll':windows_path(directory/'sevo-painter.dll')}
        (directory/'session.json').write_text(json.dumps(state,indent=2)+'\n')
        output=directory/'attach-result.json'
        command=[CLI,'run','--wait',str(directory/'sevo-painter-attach.exe'),windows_path(cef/'steamwebhelper.exe'),state['dll'],windows_path(output)]
        result=subprocess.run(command,capture_output=True,text=True,timeout=60)
        report=json.loads(output.read_text()) if output.exists() else {'launcher_exit':result.returncode,'result_file':False}
        # No original binary is changed even if attachment fails. Session remains for inspection.
        print(json.dumps({'session':str(directory),'source':state['source'],'attach':report}))
        if result.returncode:raise SystemExit(result.returncode)
        return
    directory,state=checked_session(args.session)
    if args.action=='status':
        print(json.dumps({'source':state['source'],'stats':[read_stats(f) for f in sorted(directory.glob('cef-*.stats'))]},indent=2))
    elif args.action=='finish':
        if client_state()!='stopped':raise RuntimeError('Normally quit Steam before removing loaded probe files')
        stats=[read_stats(f) for f in sorted(directory.glob('cef-*.stats'))]
        result={'finished':True,'stats':stats,'source':state['source']}
        shutil.rmtree(directory);print(json.dumps(result))
    else:
        if not args.stats_file or args.stats_file.parent.resolve()!=directory:raise RuntimeError('Select the exact live cef-*.stats file from status')
        s=read_stats(args.stats_file)
        if s['overlay_cpu_paints']<1 or s['last_width']<64 or s['last_height']<64:raise RuntimeError('No CPU overlay paint observed; keep the original renderer path')
        request=directory/f"frame-{s['pid']}-{s['last_browser']}.request"
        if request.exists():raise RuntimeError('A frame request is already pending')
        pending=directory/'frame-writing.bgra'
        subprocess.run([str(resources/'sevo-painter-frame'),str(pending),str(s['last_width']),str(s['last_height'])],check=True)
        pending.rename(request)
        print(json.dumps({'armed_once':True,'pid':s['pid'],'browser':s['last_browser'],'width':s['last_width'],'height':s['last_height']}))
if __name__=='__main__':main()
