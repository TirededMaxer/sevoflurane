"""Opt-in metadata-only CEF observer; never starts/stops Steam or writes Valve files."""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CEF_SHA = 'c85bf94462b3c79baeac63823db52d15e116eead71ea414e5d3a112c59e434d3'
CLI = '/Applications/Sevoflurane.app/Contents/Helpers/sevo'
PAYLOADS = ('sevo-overlay-observer.dll', 'sevo-overlay-observer-attach.exe')
COUNTERS = ('create_calls async_accepted async_rejected sync_nonnull sync_null '
            'render_getters display_getters unique_handlers title_entries cpu_entries gpu_entries '
            'missing_original bad_browser_id abi_rejected slot_installed slot_already slot_null '
            'slot_rejected iat_installed iat_already iat_missing records_dropped').split()

def words(name, names):
    return type(name, (C.Structure,), {'_fields_': [(field, C.c_uint64) for field in names.split()]})

Create = words('Create', 'sequence sync client window_info settings_size windowless shared_texture '
                       'external_begin_frame result_known result returned_browser cef_id')
Handler = words('Handler', 'client handler kind base_size calls')
Slot = words('Slot', 'object offset original module rva installed already nulls rejected')
class Browser(C.Structure):
    _fields_ = [(n, C.c_uint64) for n in ('browser cef_id render_handler display_handler title_entries '
               'overlay_match game_pid steam_browser_id steam_browser_type cpu_entries gpu_entries '
               'view_entries popup_entries other_entries').split()] + [
               (n, C.c_int64) for n in ('last_width last_height last_type').split()] + [
               (n, C.c_uint64) for n in ('first_tick last_tick').split()]
class Module(C.Structure):
    _fields_ = [('base', C.c_uint64), ('size', C.c_uint64), ('name', C.c_char * 64)]
class Stats(C.Structure):
    _fields_ = [('magic', C.c_char * 8)] + [(n, C.c_uint64) for n in
               ('schema bytes pid process_start ready status sequence').split()] + [('counters', C.c_uint64 * len(COUNTERS))] + [
               (n, C.c_uint64) for n in ('create_count handler_count slot_count browser_count module_count').split()] + [
               ('creates', Create * 64), ('handlers', Handler * 128), ('slots', Slot * 256),
               ('browsers', Browser * 128), ('modules', Module * 32)]
assert C.sizeof(Stats) == 51992

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def windows_path(path):
    parts = path.resolve().parts
    for i, part in enumerate(parts):
        if len(part) == 7 and part.startswith('drive_'):
            return part[-1].upper() + ':\\' + '\\'.join(parts[i + 1:])
    return 'Z:' + str(path.resolve()).replace('/', '\\')

def record(value):
    return {name: (getattr(value, name).decode('ascii', 'replace') if name == 'name'
                   else getattr(value, name)) for name, _ in value._fields_}

def decode(data):
    if len(data) != C.sizeof(Stats):
        raise RuntimeError('Observer stats size does not match schema')
    s = Stats.from_buffer_copy(data)
    if bytes(s.magic) != b'SEVOOBS1' or s.schema != 1 or s.bytes != len(data):
        raise RuntimeError('Observer stats header does not match schema')
    if s.sequence & 1:
        raise RuntimeError('Metadata update in progress; request another status snapshot')
    result = {'pid': s.pid, 'process_start': s.process_start, 'ready': bool(s.ready), 'status': s.status, 'sequence': s.sequence,
              'counters': dict(zip(COUNTERS, s.counters))}
    for field, count_name in [('creates', 'create_count'), ('handlers', 'handler_count'),
                              ('slots', 'slot_count'), ('browsers', 'browser_count'), ('modules', 'module_count')]:
        array, count = getattr(s, field), getattr(s, count_name)
        if count > len(array):
            raise RuntimeError('Observer record count exceeds schema capacity')
        result[field] = [record(v) for v in array[:count]]
    for created in result['creates']:
        if not created['sync']:
            created['async_result_signed'] = C.c_int64(created['result']).value
    return result

def read_stats(path):
    first = path.read_bytes()
    result = decode(first)
    second = path.read_bytes()
    if len(second) != len(first) or Stats.from_buffer_copy(second).sequence != result['sequence']:
        raise RuntimeError('Metadata changed during read; request another status snapshot')
    # Top-level atomic counters are monotonic samples, not a simultaneous cross-process snapshot.
    return result

def session_at(path):
    path = path.resolve()
    if path.parent != Path('/private/tmp') or not path.name.startswith('sevo-overlay-observer-'):
        raise RuntimeError('Select the exact temporary observer session directory')
    state = json.loads((path / 'session.json').read_text())
    if state.get('schema') != 1 or Path(state.get('directory', '')).resolve() != path:
        raise RuntimeError('Observer session metadata mismatch')
    for name in PAYLOADS:
        if digest(path / name) != state['payload_sha256'][name]:
            raise RuntimeError('Observer session payload hash mismatch')
    expected_config = windows_path(path) + '\n'
    if (path / 'observer.cfg').read_text() != expected_config:
        raise RuntimeError('Observer session configuration mismatch')
    return path, state

def attach(resources, steam, session):
    client = json.loads(subprocess.check_output([CLI, 'status', '--json']))['client']
    if client != 'running':
        raise RuntimeError('Steam must already be running; the observer will not start it')
    cef = steam / 'bin/cef/cef.win64'
    if digest(cef / 'libcef.dll') != CEF_SHA:
        raise RuntimeError('CEF changed; fresh ABI calibration is required')
    if session:
        directory, state = session_at(session)
    else:
        manifest = json.loads((resources / 'manifest.json').read_text())
        if manifest.get('schema') != 1 or manifest.get('cef_sha256') != CEF_SHA:
            raise RuntimeError('Observer build manifest mismatch')
        for name in PAYLOADS:
            if digest(resources / name) != manifest['payload_sha256'][name]:
                raise RuntimeError('Observer build payload hash mismatch')
        directory = Path(tempfile.mkdtemp(prefix='sevo-overlay-observer-', dir='/private/tmp'))
        os.chmod(directory, 0o700)
        for name in PAYLOADS:
            shutil.copy2(resources / name, directory / name)
        state = {'schema': 1, 'directory': str(directory), 'source': manifest['source'],
                 'cef_sha256': CEF_SHA, 'payload_sha256': manifest['payload_sha256']}
        (directory / 'session.json').write_text(json.dumps(state, indent=2) + '\n')
        (directory / 'observer.cfg').write_text(windows_path(directory) + '\n')
    output = directory / 'attach-result.json'
    output.unlink(missing_ok=True)
    command = [CLI, 'run', '--wait', str(directory / PAYLOADS[1]),
               windows_path(cef / 'steamwebhelper.exe'), windows_path(directory / PAYLOADS[0]), windows_path(output)]
    result = subprocess.run(command, capture_output=True, timeout=60)
    report = json.loads(output.read_text()) if output.exists() else {'result_file': False, 'launcher_exit': result.returncode}
    print(json.dumps({'session': str(directory), 'source': state['source'], 'attach': report}))
    return result.returncode

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('attach', 'status'))
    parser.add_argument('--session', type=Path)
    parser.add_argument('--steam', type=Path, default=Path.home() / 'Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam')
    args = parser.parse_args()
    if args.action == 'attach':
        return attach(Path(__file__).resolve().parent, args.steam, args.session)
    if not args.session:
        parser.error('status requires --session')
    directory, state = session_at(args.session)
    print(json.dumps({'source': state['source'], 'stats': [read_stats(p) for p in sorted(directory.glob('observer-*.stats'))]}, indent=2))
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
