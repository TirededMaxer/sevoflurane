"""Fresh-runner checks for the complete PE forwarder surface and native fixture."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import struct
import sys
assert os.environ.get('GITHUB_ACTIONS') == 'true'
work, out = map(Path, sys.argv[1:])
exports = json.loads(Path('cef-exports.json').read_text())['exports']
text = subprocess.check_output(['x86_64-w64-mingw32-objdump', '-p', str(work/'libcef.dll')], text=True)
# The two local trampolines retain their original ordinals; all other exports are forwarders.
for e in exports:
    assert re.search(r'\b' + re.escape(e['name']) + r'\s*$', text, re.M), e
forwarded = re.findall(r'Forwarder RVA -- sevo_libcef_original\.([^\s]+)', text)
expected = {e['name'] for e in exports} - {'cef_browser_host_create_browser','cef_browser_host_create_browser_sync'}
assert set(forwarded) == expected, (len(forwarded), len(expected))
# Verify actual PE names AND ordinals, independent of the generated .def text.
b=(work/'libcef.dll').read_bytes(); pe=struct.unpack_from('<I',b,0x3c)[0]; opt=pe+24
sections=[]
for i in range(struct.unpack_from('<H',b,pe+6)[0]):
    at=opt+struct.unpack_from('<H',b,pe+20)[0]+i*40
    virtual, rva, size, start=struct.unpack_from('<IIII',b,at+8)
    sections.append((rva,max(virtual,size),start))
def offset(rva):
    for start,length,raw in sections:
        if start<=rva<start+length:return raw+rva-start
    raise ValueError(hex(rva))
def u32(at):return struct.unpack_from('<I',b,at)[0]
def string(rva):
    at=offset(rva);return b[at:b.index(0,at)].decode('ascii')
assert struct.unpack_from('<H',b,opt)[0]==0x20b
address,size=struct.unpack_from('<II',b,opt+112)
e=struct.unpack_from('<IIHHIIIIIII',b,offset(address))
base,nfunctions,nnames,functions,names,ordinals=e[5:]
actual={}
for i in range(nnames):
    name=string(u32(offset(names)+i*4))
    ordinal=base+struct.unpack_from('<H',b,offset(ordinals)+i*2)[0]
    actual[name]=ordinal
assert actual=={e['name']:e['ordinal'] for e in exports},actual
assert nfunctions==len(exports) and nnames==len(exports)
manifest = {'source':os.environ['GITHUB_SHA'], 'original_cef_sha256':json.loads(Path('cef-exports.json').read_text())['original_sha256'],
            'proxy_sha256':hashlib.sha256((work/'libcef.dll').read_bytes()).hexdigest(),
            'native_fixture_sha256':hashlib.sha256((work/'sevo-painter-frame').read_bytes()).hexdigest(),
            'exports':len(exports), 'forwarded_exports':len(forwarded), 'experimental':True,
            'webkit_fixture_rendered':True, 'frame_validation':'passed', 'real_steam_hook':'not run',
            'input':'original Steam path, unmodified', 'gpu_replacement':'not implemented', 'continuous_webkit_output':'not implemented'}
(work/'probe-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(out/'painter-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest))
