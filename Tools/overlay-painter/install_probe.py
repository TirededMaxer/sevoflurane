"""Explicit, reversible installer for the exact Steam CEF painter experiment. No auto-start."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

CEF_SHA = "c85bf94462b3c79baeac63823db52d15e116eead71ea414e5d3a112c59e434d3"
NAMES = ["created_browsers", "render_handlers", "titles", "overlay_browsers", "cpu_paints", "gpu_paints",
         "overlay_cpu_paints", "overlay_gpu_paints", "replacement_paints", "restored_paints", "rejected_frames",
         "last_width", "last_height", "last_browser", "abi_rejected"]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def stopped():
    cli = Path('/Applications/Sevoflurane.app/Contents/Helpers/sevo')
    status = json.loads(subprocess.check_output([str(cli), 'status', '--json']))
    if status['app_running'] or status['client'] != 'stopped':
        raise RuntimeError('Normally quit Sevoflurane and Steam before installing/restoring the probe')

def read_stats(path):
    data = path.read_bytes()
    if len(data) != 16 + len(NAMES) * 8:
        raise RuntimeError('Wrong probe stats size')
    magic, version, pid, *counts = struct.unpack('<8sII' + 'q' * len(NAMES), data)
    if magic != b'SEVOSTA1' or version != 1:
        raise RuntimeError('Wrong probe stats version')
    return {'file': str(path), 'pid': pid, **dict(zip(NAMES, counts))}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['install', 'restore', 'status', 'arm'])
    p.add_argument('--steam', type=Path, default=Path.home() / 'Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam')
    p.add_argument('--stats-file', type=Path)
    args = p.parse_args()
    resources = Path(__file__).resolve().parent
    cef = args.steam / 'bin/cef/cef.win64'
    live = cef / 'libcef.dll'; backup = cef / 'sevo_libcef_original.dll'
    config = cef / 'sevo-painter-probe.txt'; ledger = cef / 'sevo-painter-state.json'
    if args.action == 'install':
        stopped()
        if backup.exists() or config.exists() or ledger.exists():
            raise RuntimeError('An existing probe must be restored first')
        if digest(live) != CEF_SHA:
            raise RuntimeError('CEF changed: this exact-build experiment is not compatible')
        payload = resources / 'libcef.dll'
        manifest = json.loads((resources / 'probe-manifest.json').read_text())
        if digest(payload) != manifest['proxy_sha256']:
            raise RuntimeError('Probe payload hash mismatch')
        directory = Path(tempfile.mkdtemp(prefix='sevo-painter-', dir='/private/tmp'))
        os.chmod(directory, 0o700)
        settings = ('Z:' + str(directory).replace('/', '\\') + '\n').encode()
        state = {'schema':1, 'directory':str(directory), 'original_sha256':CEF_SHA,
                 'proxy_sha256':manifest['proxy_sha256'], 'config_sha256':hashlib.sha256(settings).hexdigest(), 'source':manifest['source']}
        live.rename(backup)
        try:
            # Atomic placement: interrupted copy cannot be loaded as libcef.dll.
            temporary = cef / 'sevo-painter-incoming.dll'
            with temporary.open('xb') as out:
                out.write(payload.read_bytes())
                out.flush(); os.fsync(out.fileno())
            temporary.rename(live)
            config.write_bytes(settings)
            ledger.write_text(json.dumps(state, indent=2) + '\n')
        except BaseException:
            live.unlink(missing_ok=True)
            (cef / 'sevo-painter-incoming.dll').unlink(missing_ok=True)
            backup.rename(live)
            config.unlink(missing_ok=True); ledger.unlink(missing_ok=True)
            directory.rmdir()
            raise
        print(json.dumps({'installed':True, 'mode':'observe; single-frame only after explicit arm', **state}))
        return
    if not ledger.exists():
        raise RuntimeError('Probe is not installed')
    state = json.loads(ledger.read_text()); directory = Path(state['directory'])
    if args.action == 'restore':
        stopped()
        if digest(backup) != CEF_SHA or digest(live) != state['proxy_sha256'] or digest(config) != state['config_sha256']:
            raise RuntimeError('Steam files changed; refusing to overwrite them')
        backup.replace(live); config.unlink(); ledger.unlink()
        print(json.dumps({'restored':digest(live)==CEF_SHA, 'stats_directory':str(directory)}))
    elif args.action == 'status':
        print(json.dumps({'source':state['source'], 'stats':[read_stats(f) for f in sorted(directory.glob('cef-*.stats'))]}, indent=2))
    else:
        if not args.stats_file or args.stats_file.parent.resolve() != directory.resolve():
            raise RuntimeError('Select the exact live cef-*.stats file from status')
        s = read_stats(args.stats_file)
        if s['overlay_cpu_paints'] < 1 or s['last_width'] < 64 or s['last_height'] < 64:
            raise RuntimeError('No CPU overlay paint observed; do not force a different original renderer')
        request = directory / f"frame-{s['pid']}-{s['last_browser']}.request"
        if request.exists():
            raise RuntimeError('A frame request is already pending')
        pending = directory / 'frame-writing.bgra'
        subprocess.run([str(resources/'sevo-painter-frame'), str(pending), str(s['last_width']), str(s['last_height'])], check=True)
        pending.rename(request)
        print(json.dumps({'armed_once':True, 'pid':s['pid'], 'browser':s['last_browser'], 'width':s['last_width'], 'height':s['last_height']}))

if __name__ == '__main__':
    main()
