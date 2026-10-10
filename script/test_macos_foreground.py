#!/usr/bin/env python3
"""Run compiled native-window tests in a real, explicitly interactive AppKit host.

Build tests first, then invoke with --interactive, --build-path, and --agent.
Click “开始验收” in the launched window; do not operate other windows during the run.
This does not replace launching the product with script/build_and_run.sh.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sys
import subprocess

from foreground_runtime import temporary_runtime


def fingerprints(paths):
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(set(paths)) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interactive', action='store_true', required=True)
    parser.add_argument('--build-path', type=Path, required=True)
    parser.add_argument('--agent', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--method', action='append', help='Focus on an existing host method; default executes the full mandatory suite.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    host_source = root / 'script/macos_foreground_test_host.swift'
    available = json.loads(re.search(r'let available = (\[.*\])', host_source.read_text()).group(1))
    selected = args.method or available
    if not selected or len(set(selected)) != len(selected) or any(m not in available for m in selected):
        parser.error('Methods must be unique members of the mandatory host suite.')
    build, agent, output = args.build_path.resolve(), args.agent.resolve(), args.output.resolve()
    test = build / 'ShipiOSPackageTests.xctest'
    if not test.is_dir() or not agent.is_file():
        parser.error('Expected a compiled XCTest bundle and an existing test agent.')
    output.mkdir(parents=True, exist_ok=False)
    inputs = [p for directory in ('apps/macos/Sources', 'apps/macos/Tests', 'script')
              for p in (root / directory).rglob('*') if p.is_file()]
    inputs += [p for p in test.rglob('*') if p.is_file()] + [agent]
    resources = sorted(build.glob('*.bundle'))
    inputs += [p for bundle in resources for p in bundle.rglob('*') if p.is_file()]
    before = fingerprints(inputs)
    with temporary_runtime(output) as runtime:
        app = runtime / 'ShipiOSForegroundTests.app'
        binary = app / 'Contents/MacOS/ShipiOSForegroundTests'
        binary.parent.mkdir(parents=True)
        developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
        platform = developer / 'Platforms/MacOSX.platform/Developer'
        frameworks = platform / 'Library/Frameworks'
        command = ['xcrun', 'swiftc', str(root / 'script/macos_foreground_test_host.swift'),
                   '-o', str(binary), '-F', str(frameworks),
                   '-module-cache-path', str(root / '.cache/clang-module-cache')]
        for path in (frameworks, platform / 'usr/lib'):
            command += ['-Xlinker', '-rpath', '-Xlinker', str(path)]
        with (output / 'compile.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (app / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleExecutable': binary.name,
                          'CFBundleIdentifier': 'dev.shipios.foreground-tests',
                          'CFBundleName': 'ShipiOS Foreground Tests',
                          'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0',
                          'NSPrincipalClass': 'NSApplication'}, f)
        copied_test = runtime / test.name
        shutil.copytree(test, copied_test)
        for bundle in resources:
            # SwiftPM's generated Bundle.module first checks the main bundle root.
            shutil.copytree(bundle, app / bundle.name)
            # The real settings root also resolves packaged resources through
            # Contents/Resources, as the product does, without a build-cache fallback.
            shutil.copytree(bundle, app / 'Contents/Resources' / bundle.name)
        copied_agent = runtime / 'shipios-agent'
        shutil.copy2(agent, copied_agent)
        # A product workspace connects to its real helper before offering fork
        # actions. Some focused window tests use a protocol fixture instead.
        # Validate the copied helper before timing their existing action bounds;
        # first execution of the large debug binary belongs to host setup.
        with (output / 'agent-preflight.log').open('w') as helper_log:
            subprocess.run([str(copied_agent), '--help'], stdout=helper_log,
                           stderr=subprocess.STDOUT, timeout=30, check=True)
        result, log = runtime / 'result.json', runtime / 'test.log'
        descriptor = {'host': str(app), 'result': str(result), 'log': str(log)}
        (output / 'runtime.json').write_text(json.dumps(descriptor, indent=2) + '\n')
        print(json.dumps(descriptor), flush=True)
        environment = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR') if k in os.environ}
        command = ['/usr/bin/open', '-n', '-W', '--env', 'SHIPIOS_TEST_FOREGROUND_ALLOWED=1',
                   '--env', 'SHIPIOS_TEST_AGENT=' + str(copied_agent), '--stdout', str(log),
                   '--stderr', str(log), str(app), '--args', str(copied_test), str(result), *selected]
        timed_out = False
        process = subprocess.Popen(command, env=environment)
        try:
            exit_code = process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            timed_out = True
            state = json.loads(result.read_text()) if result.exists() else {}
            pid = state.get('pid')
            if isinstance(pid, int):
                actual = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
                if actual == str(binary):
                    os.kill(pid, signal.SIGTERM)
            process.terminate()
            exit_code = process.wait(timeout=10)
        state = json.loads(result.read_text()) if result.exists() else {}
        if result.exists():
            shutil.copy2(result, output / 'result.json')
        if log.exists():
            shutil.copy2(log, output / 'test.log')
        after = fingerprints(inputs)
        changed = [p for p, digest in before.items() if after.get(p) != digest]
        passed = (not timed_out and exit_code == 0 and not changed
                  and state.get('stage') == 'finished' and state.get('executed') == len(selected)
                  and state.get('failures') == 0 and state.get('unexpected') == 0
                  and state.get('skipped') == 0 and state.get('succeeded') is True)
        manifest = {'exitCode': exit_code, 'timedOut': timed_out, 'passed': passed,
                    'result': state, 'changedInputs': changed, 'sha256': before,
                    'runtime': descriptor, 'selectedMethods': selected, 'fullSuite': not bool(args.method), 'scope': ('Focused existing methods' if args.method else 'Twenty-two selected XCTest methods: nine native-window methods and thirteen voice keyboard components; not all R1–R8.')}
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(json.dumps({k: v for k, v in manifest.items() if k != 'sha256'}), flush=True)
        return 0 if passed else 1


if __name__ == '__main__':
    if os.environ.get('SHIPIOS_STORAGE_GUARDED') != '1':
        guard = Path(__file__).resolve().parent / 'dev_storage.py'
        os.execv(sys.executable, [sys.executable, str(guard), 'run', '--',
                                sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    signal.signal(signal.SIGTERM, lambda _sig, _frame: sys.exit(143))
    raise SystemExit(main())
