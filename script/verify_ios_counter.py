#!/usr/bin/env python3
"""Verify an isolated HelloShipiOS tree without implementing or repairing it.

The exit status is fail-closed: building is not UI verification, and zero,
skipped, unexpected, or changed-input tests never produce a passing report.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
TEST = 'HelloShipiOSUITests/testCounterStartsAtZeroIncrementsTwiceAndResets()'
SELECTION = 'HelloShipiOSUITests/' + TEST.removesuffix('()')


def fingerprints(project):
    return {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(project.rglob('*')) if p.is_file()
            and not any(part.startswith('.') for part in p.relative_to(project).parts)
            and (p.suffix == '.swift' or p.name == 'project.pbxproj' or p.suffix == '.xcscheme')}


def counter_passed(summary, tree):
    leaves = []

    def walk(node):
        if node.get('nodeType') == 'Test Case':
            leaves.append(node)
        for child in node.get('children', []):
            walk(child)

    for node in tree.get('testNodes', []):
        walk(node)
    return (summary.get('result') == 'Passed'
            and summary.get('totalTestCount') == summary.get('passedTests') == 1
            and all(summary.get(k) == 0 for k in ('failedTests', 'skippedTests', 'expectedFailures'))
            and len(leaves) == 1 and leaves[0].get('nodeIdentifier') == TEST
            and leaves[0].get('result') == 'Passed')


def run(command, log, timeout):
    started = time.monotonic()
    with log.open('w') as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        timed_out = False
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
    return {'exitCode': code, 'timedOut': timed_out, 'seconds': time.monotonic() - started,
            'command': command, 'log': str(log)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True, help='Isolated HelloShipiOS directory')
    parser.add_argument('--simulator', required=True, help='Booted dedicated ShipiOS-v0.1 simulator UUID')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory; never overwritten')
    parser.add_argument('--timeout', type=int, default=300, help='Per Xcode command, seconds (30–600)')
    args = parser.parse_args()
    project, output = args.project.resolve(), args.output.resolve()
    if not 30 <= args.timeout <= 600:
        parser.error('Timeout must be between 30 and 600 seconds.')
    if not (project / 'HelloShipiOS.xcodeproj').is_dir():
        parser.error('HelloShipiOS.xcodeproj is missing.')
    if project == (ROOT / 'fixtures/HelloShipiOS').resolve():
        parser.error('Copy the fixture first; verification requires an isolated project.')
    protected = ['HelloShipiOSUITests.swift', 'HelloShipiOS.xcodeproj/project.pbxproj',
                 'HelloShipiOS.xcodeproj/xcshareddata/xcschemes/HelloShipiOS.xcscheme']
    for relative in protected:
        expected, actual = ROOT / 'fixtures/HelloShipiOS' / relative, project / relative
        if not actual.is_file() or actual.read_bytes() != expected.read_bytes():
            parser.error('Fixed acceptance inputs must remain unchanged: ' + relative)
    if output.exists() or output == project or project in output.parents:
        parser.error('Evidence must use a new directory outside the project.')
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
    device = next((d for rows in devices['devices'].values() for d in rows
                   if d['udid'] == args.simulator), None)
    if not device or device['state'] != 'Booted' or not device['name'].startswith('ShipiOS-v0.1'):
        parser.error('Use a booted dedicated ShipiOS-v0.1 simulator; personal devices are not modified.')
    output.mkdir(parents=True)
    before = fingerprints(project)
    manifest = {'schemaVersion': 1, 'startedAtUTC': datetime.now(timezone.utc).isoformat(),
                'project': str(project), 'device': device,
                'verifierSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'sourceSHA256': before, 'verification': 'not_run', 'passed': False,
                'modelEvidence': 'not_provided', 'automaticRepairAttempts': 0, 'steps': []}
    common = ['xcodebuild', '-project', str(project / 'HelloShipiOS.xcodeproj'),
              '-scheme', 'HelloShipiOS', '-configuration', 'Debug',
              '-destination', 'platform=iOS Simulator,id=' + args.simulator,
              '-destination-timeout', '30', '-derivedDataPath', str(ROOT / '.cache/xcode-derived-data'),
              '-disableAutomaticPackageResolution', '-skipPackageUpdates',
              '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
              'CODE_SIGNING_ALLOWED=NO']
    try:
        for action, name in [('build-for-testing', 'build'), ('test-without-building', 'test')]:
            result = output / (name + '.xcresult')
            command = [sys.executable, str(ROOT / 'script/dev_storage.py'), 'run', '--', *common,
                       '-resultBundlePath', str(result), action]
            if name == 'test':
                command.append('-only-testing:' + SELECTION)
            step = run(command, output / (name + '.log'), args.timeout)
            manifest['steps'].append(step)
            if step['timedOut'] or step['exitCode'] != 0:
                manifest['verification'] = 'failed' if name == 'test' else 'not_run'
                manifest['failureStage'] = name
                break
            if name == 'build':
                products = ROOT / '.cache/xcode-derived-data/Build/Products/Debug-iphonesimulator'
                binaries = ['HelloShipiOS.app/HelloShipiOS',
                            'HelloShipiOSUITests-Runner.app/PlugIns/HelloShipiOSUITests.xctest/HelloShipiOSUITests']
                manifest['buildSHA256'] = {f: hashlib.sha256((products / f).read_bytes()).hexdigest()
                                          for f in binaries}
        if len(manifest['steps']) == 2 and (output / 'test.xcresult').is_dir():
            reports = {}
            for kind in ('summary', 'tests'):
                reports[kind] = json.loads(subprocess.check_output(
                    ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path',
                     str(output / 'test.xcresult'), '--compact'], timeout=30))
                (output / (kind + '.json')).write_text(json.dumps(reports[kind], indent=2) + '\n')
            manifest['testSummary'] = reports['summary']
            manifest['verification'] = 'passed' if counter_passed(reports['summary'], reports['tests']) else 'failed'
            if manifest['verification'] == 'failed':
                manifest['failureStage'] = 'test'
    except Exception as error:
        manifest['error'] = type(error).__name__ + ': ' + str(error)
        manifest['passed'] = False
    finally:
        after = fingerprints(project)
        manifest['changedInputs'] = [f for f in sorted(set(before) | set(after))
                                     if before.get(f) != after.get(f)]
        manifest['passed'] = (manifest['verification'] == 'passed' and not manifest['changedInputs']
                              and not manifest.get('error') and len(manifest['steps']) == 2
                              and all(s['exitCode'] == 0 and not s['timedOut'] for s in manifest['steps']))
        manifest['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: v for k, v in manifest.items() if k not in ('sourceSHA256', 'device', 'testSummary')}, indent=2))
    return 0 if manifest['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
