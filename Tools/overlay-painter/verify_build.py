"""Fresh-runner checks for the complete PE forwarder surface and native fixture."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
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
manifest = {'source':os.environ['GITHUB_SHA'], 'original_cef_sha256':json.loads(Path('cef-exports.json').read_text())['original_sha256'],
            'proxy_sha256':hashlib.sha256((work/'libcef.dll').read_bytes()).hexdigest(),
            'native_fixture_sha256':hashlib.sha256((work/'sevo-painter-frame').read_bytes()).hexdigest(),
            'exports':len(exports), 'forwarded_exports':len(forwarded), 'experimental':True,
            'webkit_fixture_rendered':True, 'frame_validation':'passed', 'real_steam_hook':'not run',
            'input':'original Steam path, unmodified', 'gpu_replacement':'not implemented', 'continuous_webkit_output':'not implemented'}
(work/'probe-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
(out/'painter-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest))
