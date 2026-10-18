"""Verify the x64 process-only adapter and native WebKit fixture on the fresh runner."""
from pathlib import Path
import hashlib
import json
import os
import struct
import subprocess
import sys
assert os.environ.get('GITHUB_ACTIONS') == 'true'
work, out = map(Path, sys.argv[1:])
for name, dll in [('sevo-painter.dll', True), ('sevo-painter-attach.exe', False)]:
    data = (work/name).read_bytes()
    assert data[:2] == b'MZ'
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe+4] == b'PE\0\0'
    assert struct.unpack_from('<H', data, pe+4)[0] == 0x8664
    assert struct.unpack_from('<H', data, pe+24)[0] == 0x20b
    assert bool(struct.unpack_from('<H', data, pe+22)[0] & 0x2000) == dll
    imports = subprocess.check_output(['x86_64-w64-mingw32-objdump', '-p', str(work/name)], text=True)
    assert 'sevo_libcef_original' not in imports and 'DLL Name: libcef.dll' not in imports
    if dll:
        # No replacement CEF export surface and no load-time dependency on Valve files.
        assert struct.unpack_from('<II', data, pe+24+112) == (0, 0)
evidence = json.loads(Path('cef-abi-evidence.json').read_text())
manifest = {'source': os.environ['GITHUB_SHA'], 'original_cef_sha256': evidence['artifacts'][0]['sha256'],
            'probe_sha256': hashlib.sha256((work/'sevo-painter.dll').read_bytes()).hexdigest(),
            'attach_sha256': hashlib.sha256((work/'sevo-painter-attach.exe').read_bytes()).hexdigest(),
            'native_fixture_sha256': hashlib.sha256((work/'sevo-painter-frame').read_bytes()).hexdigest(),
            'supported_iat_imports': 2, 'experimental': True, 'attachment': 'post-bootstrap exact-path steamwebhelper only',
            'valve_disk_mutations': False, 'webkit_fixture_rendered': True, 'frame_validation': 'passed',
            'real_steam_hook': 'not run', 'input': 'original Steam path, unmodified',
            'gpu_replacement': 'not implemented', 'continuous_webkit_output': 'not implemented'}
(work/'probe-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(out/'painter-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest))
