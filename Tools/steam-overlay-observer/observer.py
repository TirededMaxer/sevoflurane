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
HELPER_SHA = '5ee6df1a5a2237dd3efb7d7042b02ba20f2238ba15d961b1a10ef6d575c59362'
ATTACHER = 'sevo-overlay-observer-attach.exe'
KINDS = {
    'capi': {'dll': 'sevo-overlay-observer.dll', 'prefix': 'sevo-overlay-observer-',
             'config': 'observer.cfg', 'stats': 'observer-*.stats'},
    'cpp': {'dll': 'sevo-overlay-cpp-observer.dll', 'prefix': 'sevo-overlay-cpp-observer-',
            'config': 'cpp-observer.cfg', 'stats': 'cpp-observer-*.stats'},
}
PAYLOADS = (KINDS['capi']['dll'], ATTACHER, KINDS['cpp']['dll'])
CPP_COUNTERS = ('cpu_entries gpu_entries missing_original native_id_unreadable records_dropped '
                'slot_installed slot_already slot_rejected rollback_failed').split()


def payloads_for(kind):
    if not isinstance(kind, str) or kind not in KINDS:
        raise RuntimeError('Unknown observer kind')
    return (KINDS[kind]['dll'], ATTACHER)
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
CppSlot = words('CppSlot', 'slot_rva expected_rva original observed installed rejected')
class CppPainter(C.Structure):
    _fields_ = [(n, C.c_uint64) for n in ('painter native_browser_id identity_valid cpu_entries gpu_entries '
               'view_entries popup_entries other_entries').split()] + [
               (n, C.c_int64) for n in ('last_width last_height last_type').split()] + [
               (n, C.c_uint64) for n in ('first_tick last_tick').split()]
class Header(C.Structure):
    _fields_ = [('magic', C.c_char * 8)] + [(n, C.c_uint64) for n in
               ('schema bytes pid process_start ready status sequence').split()]
class CppStats(C.Structure):
    _fields_ = Header._fields_ + [('counters', C.c_uint64 * len(CPP_COUNTERS))] + [
               (n, C.c_uint64) for n in ('slot_count painter_count helper_base image_bytes').split()] + [
               ('slots', CppSlot * 2), ('painters', CppPainter * 128)]
assert C.sizeof(CppStats) == 13576
assert Stats.sequence.offset == CppStats.sequence.offset == Header.sequence.offset == 56

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

def decode(data, kind=None):
    actual_kind = {b'SEVOOBS1': 'capi', b'SEVOCPP1': 'cpp'}.get(data[:8])
    if actual_kind is None or (kind is not None and kind != actual_kind):
        raise RuntimeError('Observer stats kind does not match schema/session')
    cls, counters = (Stats, COUNTERS) if actual_kind == 'capi' else (CppStats, CPP_COUNTERS)
    if len(data) != C.sizeof(cls):
        raise RuntimeError('Observer stats size does not match schema')
    s = cls.from_buffer_copy(data)
    if s.schema != 1 or s.bytes != len(data):
        raise RuntimeError('Observer stats header does not match schema')
    if s.sequence & 1:
        raise RuntimeError('Metadata update in progress; request another status snapshot')
    result = {'kind': actual_kind, 'pid': s.pid, 'process_start': s.process_start,
              'ready': bool(s.ready), 'status': s.status, 'sequence': s.sequence,
              'counters': dict(zip(counters, s.counters))}
    arrays = [('slots', 'slot_count'), ('painters', 'painter_count')] if actual_kind == 'cpp' else [
        ('creates', 'create_count'), ('handlers', 'handler_count'),
        ('slots', 'slot_count'), ('browsers', 'browser_count'), ('modules', 'module_count')]
    for field, count_name in arrays:
        array, count = getattr(s, field), getattr(s, count_name)
        if count > len(array):
            raise RuntimeError('Observer record count exceeds schema capacity')
        result[field] = [record(v) for v in array[:count]]
    if actual_kind == 'capi':
        for created in result['creates']:
            if not created['sync']:
                created['async_result_signed'] = C.c_int64(created['result']).value
    else:
        result.update(helper_base=s.helper_base, image_bytes=s.image_bytes)
    return result


def read_stats(path, kind=None):
    first = path.read_bytes()
    result = decode(first, kind)
    second = path.read_bytes()
    if (len(second) != len(first) or second[:56] != first[:56] or
            Header.from_buffer_copy(second).sequence != result['sequence']):
        raise RuntimeError('Metadata changed during read; request another status snapshot')
    # Atomic counters are monotonic samples, not a simultaneous cross-process snapshot.
    return result


def session_at(path, kind=None):
    path = path.resolve()
    if path.parent != Path('/private/tmp') or not any(path.name.startswith(v['prefix']) for v in KINDS.values()):
        raise RuntimeError('Select the exact temporary observer session directory')
    state = json.loads((path / 'session.json').read_text())
    if state.get('schema') != 1 or Path(state.get('directory', '')).resolve() != path:
        raise RuntimeError('Observer session metadata mismatch')
    actual_kind = state.get('kind', 'capi')  # Preserve existing schema-1 CAPI sessions.
    names = payloads_for(actual_kind)
    if kind is not None and kind != actual_kind:
        raise RuntimeError('Observer session kind mismatch')
    spec = KINDS[actual_kind]
    if not path.name.startswith(spec['prefix']):
        raise RuntimeError('Observer session directory kind mismatch')
    if actual_kind == 'cpp' and state.get('helper_sha256') != HELPER_SHA:
        raise RuntimeError('Observer C++ session helper identity mismatch')
    for name in names:
        if digest(path / name) != state['payload_sha256'][name]:
            raise RuntimeError('Observer session payload hash mismatch')
    if (path / spec['config']).read_text() != windows_path(path) + '\n':
        raise RuntimeError('Observer session configuration mismatch')
    return path, state


def attach(resources, steam, session, kind=None):
    if session:
        directory, state = session_at(session, kind)
        kind = state.get('kind', 'capi')
    else:
        kind = kind or 'capi'
    names = payloads_for(kind)
    spec = KINDS[kind]
    client = json.loads(subprocess.check_output([CLI, 'status', '--json']))['client']
    if client != 'running':
        raise RuntimeError('Steam must already be running; the observer will not start it')
    cef = steam / 'bin/cef/cef.win64'
    if digest(cef / 'libcef.dll') != CEF_SHA:
        raise RuntimeError('CEF changed; fresh ABI calibration is required')
    if kind == 'cpp' and digest(cef / 'steamwebhelper.exe') != HELPER_SHA:
        raise RuntimeError('Steam helper changed; fresh C++ ABI calibration is required')
    if not session:
        manifest = json.loads((resources / 'manifest.json').read_text())
        if manifest.get('schema') != 1 or manifest.get('cef_sha256') != CEF_SHA:
            raise RuntimeError('Observer build manifest mismatch')
        if kind == 'cpp' and manifest.get('helper_sha256') != HELPER_SHA:
            raise RuntimeError('Observer C++ build helper identity mismatch')
        for name in names:
            if digest(resources / name) != manifest['payload_sha256'][name]:
                raise RuntimeError('Observer build payload hash mismatch')
        directory = Path(tempfile.mkdtemp(prefix=spec['prefix'], dir='/private/tmp'))
        os.chmod(directory, 0o700)
        for name in names:
            shutil.copy2(resources / name, directory / name)
        state = {'schema': 1, 'kind': kind, 'directory': str(directory), 'source': manifest['source'],
                 'cef_sha256': CEF_SHA, 'payload_sha256': {name: manifest['payload_sha256'][name] for name in names}}
        if kind == 'cpp':
            state['helper_sha256'] = HELPER_SHA
        (directory / 'session.json').write_text(json.dumps(state, indent=2) + '\n')
        (directory / spec['config']).write_text(windows_path(directory) + '\n')
    output = directory / 'attach-result.json'
    output.unlink(missing_ok=True)
    command = [CLI, 'run', '--wait', str(directory / ATTACHER),
               windows_path(cef / 'steamwebhelper.exe'), windows_path(directory / spec['dll']), windows_path(output)]
    result = subprocess.run(command, capture_output=True, timeout=60)
    report = json.loads(output.read_text()) if output.exists() else {'result_file': False, 'launcher_exit': result.returncode}
    print(json.dumps({'kind': kind, 'session': str(directory), 'source': state['source'], 'attach': report}))
    return result.returncode

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('attach', 'status'))
    parser.add_argument('--session', type=Path)
    parser.add_argument('--kind', choices=tuple(KINDS), help='Default capi; an existing session determines its kind')
    parser.add_argument('--steam', type=Path, default=Path.home() / 'Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam')
    args = parser.parse_args()
    if args.action == 'attach':
        return attach(Path(__file__).resolve().parent, args.steam, args.session, args.kind)
    if not args.session:
        parser.error('status requires --session')
    directory, state = session_at(args.session, args.kind)
    kind = state.get('kind', 'capi')
    print(json.dumps({'kind': kind, 'source': state['source'],
                      'stats': [read_stats(p, kind) for p in sorted(directory.glob(KINDS[kind]['stats']))]}, indent=2))
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
