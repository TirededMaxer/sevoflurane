#!/usr/bin/env python3
"""Build only the Cocoa UI compatibility edits against an existing Wine build."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--wine-source', type=Path, required=True)
parser.add_argument('--wine-build', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--test', action='store_true', help='Run policy and AppKit regression checks (desktop session required).')
options = parser.parse_args()
package = Path(__file__).resolve().parent
source = options.wine_source.resolve()
build = options.wine_build.resolve()
output = options.output.resolve()
output.mkdir(parents=True, exist_ok=True)
stage = output / 'source'
assert not stage.exists(), 'Use a fresh output folder; never overwrite staged changes.'
staged_driver = stage / 'dlls/winemac.drv'
staged_driver.mkdir(parents=True)
changed = ['cocoa_app', 'cocoa_window', 'cocoa_status_item']
for name in ['cocoa_app.h'] + [stem + '.m' for stem in changed]:
    shutil.copy2(source / 'dlls/winemac.drv' / name, staged_driver / name)
subprocess.run(['patch', '--batch', '--forward', '-p1', '-i', str(package / 'sevoflurane-crossover-ui.patch')], cwd=stage, check=True)
commands = json.loads((build / 'compile_commands.json').read_text())
for stem in changed:
    row = next(entry for entry in commands if entry['file'].endswith('/' + stem + '.m'))
    arguments = shlex.split(row['command'])
    arguments[arguments.index('-o') + 1] = str(output / (stem + '.o'))
    arguments[arguments.index(row['file'])] = str(staged_driver / (stem + '.m'))
    subprocess.run(arguments, cwd=build, check=True)

# Keep the original driver object list and link flags, replacing only our three objects.
# This preserves the input ABI and the user's existing HID and presentation patches.
lines = (build / 'Makefile').read_text().replace('\\\n', ' ').splitlines()
index = next(index for index, line in enumerate(lines) if line.startswith('dlls/winemac.drv/winemac.so:'))
variables = {}
for line in lines:
    if line.startswith(('CC = ', 'LDFLAGS = ')):
        key, value = line.split(' = ', 1)
        variables[key] = value
command = lines[index + 1].strip().replace('$@', 'SEVO_OUTPUT')
for key, value in variables.items():
    command = command.replace('$(' + key + ')', value)
assert '$(' not in command, 'Resolve additional Makefile variables before linking.'
arguments = shlex.split(command)
arguments[arguments.index('SEVO_OUTPUT')] = str(output / 'winemac.so')
for stem in changed:
    arguments[arguments.index('dlls/winemac.drv/' + stem + '.o')] = str(output / (stem + '.o'))
subprocess.run(arguments, cwd=build, check=True)
candidate = output / 'winemac.so'
subprocess.run(['codesign', '--force', '--sign', '-', str(candidate)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(candidate)], check=True)

def exports(path):
    return sorted(line.split()[-1] for line in subprocess.check_output(['nm', '-gU', str(path)], text=True).splitlines())

assert exports(candidate) == exports(build / 'dlls/winemac.drv/winemac.so'), 'Driver exports changed.'
if options.test:
    test_output = output / 'tests'
    test_output.mkdir()
    policy = test_output / 'policy'
    subprocess.run(['clang', '-I' + str(staged_driver), str(package / 'tests/policy.c'), '-o', str(policy)], check=True)
    subprocess.run([str(policy)], check=True)
    subprocess.run(['python3', str(package / 'tests/appkit.py'), '--source', str(staged_driver), '--output', str(test_output)], check=True)
result = {'sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(), 'exports_unchanged': True, 'signature_valid': True, 'regression_checks_run': options.test}
(output / 'validation.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
