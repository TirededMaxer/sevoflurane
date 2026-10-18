"""Cloud-only PE identity and payload manifest; no target execution."""
import hashlib
import json
from pathlib import Path
import struct
import sys
from observer import CEF_SHA, PAYLOADS

work, output, source = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
hashes = {}
for name in PAYLOADS:
    data = (work / name).read_bytes()
    if data[:2] != b'MZ':
        raise SystemExit('Not a PE payload: ' + name)
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0' or struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
        raise SystemExit('Payload is not AMD64: ' + name)
    if struct.unpack_from('<H', data, pe + 24)[0] != 0x20b:
        raise SystemExit('Payload is not PE32+: ' + name)
    hashes[name] = hashlib.sha256(data).hexdigest()
manifest = {'schema': 1, 'source': source, 'cef_sha256': CEF_SHA,
            'payload_sha256': hashes, 'tests': {
                'callback_fixture': 'Same source, Microsoft x64 ABI on macOS x86_64/Rosetta',
                'windows_payloads': 'Cross-compiled PE32+ AMD64; real Steam runtime not exercised in CI'}}
(work / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(output / 'observer-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
