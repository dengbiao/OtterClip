#!/bin/bash
# All Apple/signing commands are replaced in a temporary script copy.
# No certificates, credentials, network, mounted images or system clipboard are used.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$PWD/scripts/notarize-release.sh" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
mock_source = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys, zipfile
p = pathlib.Path
tool = p(sys.argv[0]).name
args = sys.argv[1:]
scenario = os.environ['FIXTURE_CASE']
events = p(os.environ['FIXTURE_EVENTS'])
state_file = p(os.environ['FIXTURE_STATE'])
def event(value):
    with events.open('a') as file: file.write(value + '\n')
def stop(message='fixture rejection'):
    print(message, file=sys.stderr)
    sys.exit(1)
def kind(path): return 'dmg' if str(path).endswith('.dmg') else 'app'
if tool == 'codesign':
    target = p(args[-1])
    if '--display' in args:
        team = 'WRONGTEAM0' if scenario == 'wrong_team' else 'TEAM123456'
        authority = 'Apple Development: Fixture' if scenario == 'development_identity' else 'Developer ID Application: Fixture'
        print('TeamIdentifier=' + team, file=sys.stderr)
        print('Authority=' + authority, file=sys.stderr)
        if scenario != 'no_runtime': print('CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded', file=sys.stderr)
        if scenario != 'no_timestamp': print('Timestamp=Oct 25, 2026 at 1:00:00 AM', file=sys.stderr)
    elif '--verify' in args:
        event('verify.' + kind(target))
        if scenario == 'invalid_signature': stop()
    else:
        event('sign.' + kind(target))
        if '--timestamp' not in args: stop('missing timestamp')
elif tool == 'security':
    event('identity.list')
    if scenario != 'no_identity':
        print('  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAM123456)"')
        print('     1 valid identities found')
elif tool == 'lipo':
    print('x86_64' if scenario == 'intel' else 'arm64')
elif tool == 'xcrun':
    if args[0] == '--find':
        if scenario == 'missing_tool': stop()
        print('/fixture/' + args[1])
    elif args[:2] == ['notarytool', 'submit']:
        archive = p(args[2])
        label = kind(archive)
        event('submit.' + label)
        if '--keychain-profile' not in args or '--wait' not in args or '--output-format' not in args: stop('unsafe submit arguments')
        if any(a in args for a in ['--password', '--apple-id', '--key', '--force']): stop('unexpected credentials')
        if scenario == 'auth_failure': stop('credential profile unavailable')
        rejected = scenario == 'notary_invalid' or (scenario == 'dmg_invalid' and label == 'dmg')
        identifier = '11111111-1111-4111-8111-111111111111' if label == 'app' else '22222222-2222-4222-8222-222222222222'
        print(json.dumps({'id': identifier, 'status': 'Invalid' if rejected else 'Accepted'}))
    elif args[:2] == ['notarytool', 'log']:
        identifier = args[2]
        label = 'app' if identifier.startswith('1') else 'dmg'
        event('log.' + label)
        rejected = scenario == 'notary_invalid' or (scenario == 'dmg_invalid' and label == 'dmg')
        issues = [{'severity': 'error', 'message': 'Fixture'}] if scenario == 'log_error' else None
        if scenario == 'warning': issues = [{'severity': 'warning', 'message': 'Fixture warning'}]
        p(args[-1]).write_text(json.dumps({'jobId': identifier, 'status': 'Invalid' if rejected else 'Accepted', 'issues': issues}))
    elif args[:2] == ['stapler', 'staple']:
        target = p(args[2]); label = kind(target)
        event('staple.' + label)
        if scenario == 'staple_failure': stop()
        ticket = p(str(target) + '.ticket') if label == 'dmg' else target / 'Contents/CodeResources'
        ticket.write_text('Fixture notary ticket')
    elif args[:2] == ['stapler', 'validate']:
        target = p(args[2]); label = kind(target)
        event('validate.ticket.' + label)
        ticket = p(str(target) + '.ticket') if label == 'dmg' else target / 'Contents/CodeResources'
        if not ticket.is_file(): stop('ticket missing')
    else: stop('unexpected xcrun operation')
elif tool == 'ditto':
    if '-c' in args:
        app, archive = map(p, args[-2:])
        event('zip.submission' if archive.name == 'submission.zip' else 'zip.final')
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
            for file in app.rglob('*'):
                if file.is_file(): output.write(file, file.relative_to(app.parent))
    elif '-x' in args:
        archive, destination = map(p, args[-2:]); event('zip.unpack')
        with zipfile.ZipFile(archive) as input:
            input.extractall(destination)
        (destination / 'OtterClip.app/Contents/MacOS/OtterClip').chmod(0o755)
    else:
        app, destination = map(p, args)
        shutil.copytree(app, destination, symlinks=True)
elif tool == 'hdiutil':
    if args[0] == 'create':
        event('dmg.create')
        state_file.write_text(args[args.index('-srcfolder') + 1])
        p(args[-1]).write_text('Fixture disk image')
    elif args[0] == 'verify': event('dmg.verify')
    elif args[0] == 'attach':
        event('dmg.attach')
        mount = p(args[args.index('-mountpoint') + 1])
        shutil.copytree(p(state_file.read_text()) / 'OtterClip.app', mount / 'OtterClip.app')
    elif args[0] == 'detach': event('dmg.detach')
    else: stop('unexpected hdiutil operation')
elif tool in ['spctl', 'syspolicy_check']:
    event('gatekeeper.' + kind(p(args[-1])))
    if scenario == 'gatekeeper_failure': stop()
else: stop('unexpected tool')
'''

passed = 0
with tempfile.TemporaryDirectory(prefix='OtterClip-notary-fixtures-') as temporary:
    root = Path(temporary)
    mock = root / 'mock'
    mock.mkdir()
    substitutions = {
        'CODESIGN': '/usr/bin/codesign', 'SECURITY': '/usr/bin/security',
        'XCRUN': '/usr/bin/xcrun', 'LIPO': '/usr/bin/lipo', 'DITTO': '/usr/bin/ditto',
        'HDIUTIL': '/usr/bin/hdiutil', 'SPCTL': '/usr/sbin/spctl',
        'SYSPOLICY': '/usr/bin/syspolicy_check',
    }
    script_text = source.read_text()
    for variable, original in substitutions.items():
        tool = mock / Path(original).name
        tool.write_text(mock_source)
        tool.chmod(0o755)
        script_text = script_text.replace(variable + '=' + original, variable + '=' + str(tool))
    script = root / 'notarize-release.sh'
    script.write_text(script_text)
    script.chmod(0o755)

    def check(condition, description):
        global passed
        if not condition:
            raise AssertionError(description)
        passed += 1

    def run_case(scenario, mode='--submit', overrides=None, identity_sha=False):
        folder = root / f'{scenario}-{mode[2:]}-{passed}'
        folder.mkdir()
        app = folder / 'Input.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        executable = app / 'Contents/MacOS/OtterClip'
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'app.clipshelf.mac',
            'CFBundleExecutable': 'OtterClip',
            'CFBundleShortVersionString': '1.3.1',
        }))
        before = {p.relative_to(app): p.read_bytes() for p in app.rglob('*') if p.is_file()}
        output = folder / 'output'
        events = folder / 'events'
        env = dict(os.environ, CODE_SIGN_IDENTITY=('A' * 40 if identity_sha else 'Developer ID Application: Fixture (TEAM123456)'),
                   EXPECTED_TEAM_ID='TEAM123456', NOTARY_KEYCHAIN_PROFILE='fixture-profile',
                   FIXTURE_CASE=scenario, FIXTURE_EVENTS=str(events), FIXTURE_STATE=str(folder / 'state'))
        env.pop('NOTARY_KEYCHAIN', None)
        env.pop('NOTARIZE_TIMEOUT', None)
        if overrides: env.update(overrides)
        if scenario == 'output_inside_app': output = app / 'nested/output'
        if scenario == 'existing_artifact':
            output.mkdir()
            (output / 'SHA256SUMS').write_text('Previously published checksums')
        command = [str(script)] + ([mode] if mode else []) + [str(app), str(output)]
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        after = {p.relative_to(app): p.read_bytes() for p in app.rglob('*') if p.is_file()}
        check(before == after, scenario + ': input app remains unchanged')
        sequence = events.read_text().splitlines() if events.exists() else []
        return result, output, sequence

    for mode in ['', '--check-only', '--dry-run']:
        result, output, events = run_case('success', mode)
        check(result.returncode == 0, mode + ': preflight succeeds: ' + result.stderr)
        check(not output.exists() and not any(e.startswith('submit.') for e in events), mode + ': no writes or submission')

    for scenario in ['success', 'intel', 'warning']:
        result, output, events = run_case(scenario, identity_sha=scenario == 'intel')
        check(result.returncode == 0, scenario + ': release succeeds: ' + result.stderr)
        arch = 'x86_64' if scenario == 'intel' else 'arm64'
        base = f'OtterClip-1.3.1-{arch}'
        check((output / (base + '.dmg')).is_file() and (output / (base + '.zip')).is_file(), scenario + ': architecture-specific assets')
        lines = (output / 'SHA256SUMS').read_text().splitlines()
        check(len(lines) == 2 and all(line.split()[0] == hashlib.sha256((output / line.split()[-1]).read_bytes()).hexdigest() for line in lines), scenario + ': checksums match final files')
        expected = ['zip.submission', 'submit.app', 'log.app', 'staple.app', 'zip.final', 'zip.unpack',
                    'dmg.create', 'sign.dmg', 'submit.dmg', 'log.dmg', 'staple.dmg', 'dmg.verify', 'dmg.attach', 'dmg.detach']
        positions = [events.index(item) for item in expected]
        check(positions == sorted(positions), scenario + ': correct signing/notarization/stapling order')
        check(events.count('gatekeeper.app') == 3 and events.count('validate.ticket.app') == 3, scenario + ': app, extracted ZIP, and mounted DMG are verified')
        logs = list((output / 'private/notarization').glob('run.*/*'))
        check(logs and all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in logs), scenario + ': diagnostics are private')

    for scenario in ['invalid_signature', 'wrong_team', 'no_runtime', 'no_timestamp', 'development_identity',
                     'no_identity', 'missing_tool', 'auth_failure', 'notary_invalid', 'dmg_invalid',
                     'log_error', 'staple_failure', 'gatekeeper_failure']:
        result, output, events = run_case(scenario)
        check(result.returncode != 0, scenario + ': rejected')
        check(not (output / 'SHA256SUMS').exists() and not list(output.glob('*.dmg')) and not list(output.glob('*.zip')),
              scenario + ': no final assets or checksums')
        if scenario in ['invalid_signature', 'wrong_team', 'no_runtime', 'no_timestamp', 'development_identity', 'no_identity', 'missing_tool']:
            check(not any(e.startswith('submit.') for e in events), scenario + ': rejected before upload')
        if scenario == 'notary_invalid':
            check('staple.app' not in events and 'submit.dmg' not in events, scenario + ': no processing after rejection')
        if scenario == 'log_error':
            check('staple.app' not in events, scenario + ': Accepted summary cannot hide Apple-log errors')

    for name, value in [('CODE_SIGN_IDENTITY', '-'), ('NOTARY_KEYCHAIN_PROFILE', ''),
                        ('EXPECTED_TEAM_ID', 'bad'), ('NOTARIZE_TIMEOUT', 'forever')]:
        result, output, events = run_case('success', '--check-only', {name: value})
        check(result.returncode != 0 and not output.exists() and not any(e.startswith('submit.') for e in events), name + ': invalid configuration fails offline')

    result, output, events = run_case('output_inside_app')
    check(result.returncode != 0 and not output.parent.exists() and not any(e.startswith('submit.') for e in events),
          'output inside app: rejected before directory creation or upload')
    result, output, events = run_case('existing_artifact')
    check(result.returncode != 0 and (output / 'SHA256SUMS').read_text() == 'Previously published checksums' and not any(e.startswith('submit.') for e in events),
          'existing artifacts: preserved without upload')

print(f'Notarization pipeline fixtures: {passed} checks passed; no real signing, keychain, notarization, or mounts.')
PY
