#!/usr/bin/env python3
"""Regression tests for destructive cleanup and storage exhaustion safeguards."""
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import dev_storage as storage
from foreground_runtime import temporary_runtime


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        # Nested guards must use the fixture's managed paths, rather than inherit
        # the outer repository guard's absolute cache locations.
        environment = patch.dict(os.environ, {
            'SHIPIOS_BUILD_CACHE_ROOT': str(self.root / '.cache'),
            'CARGO_TARGET_DIR': str(self.root / 'target'),
        })
        environment.start()
        self.addCleanup(environment.stop)

    def test_reuses_fixed_paths_and_rejects_arbitrary_or_symlink_targets(self):
        env = storage.build_environment(self.root, {})
        self.assertEqual(env['CARGO_TARGET_DIR'], str(self.root / 'target'))
        self.assertEqual(env['CARGO_INCREMENTAL'], '0')
        for n in (1, 2):
            slot = self.root / '.cache/isolated' / str(n)
            env = storage.build_environment(self.root, {
                'CARGO_TARGET_DIR': str(slot / 'target'),
                'SHIPIOS_BUILD_CACHE_ROOT': str(slot)})
            self.assertEqual(env['SHIPIOS_BUILD_CACHE_ROOT'], str(slot))
        with self.assertRaises(RuntimeError):
            storage.build_environment(self.root, {'CARGO_TARGET_DIR': '.cache/phase-999'})
        (self.root / 'target').symlink_to('/tmp', target_is_directory=True)
        with self.assertRaises(RuntimeError):
            storage.build_environment(self.root, {})

    def test_over_budget_refuses_to_start_child(self):
        marker = self.root / 'started'
        with patch.object(storage, 'cache_bytes', return_value=100), self.assertRaises(RuntimeError):
            storage.run_guarded(self.root, [sys.executable, '-c',
                                f'open({str(marker)!r}, "w").close()'],
                                min_free=0, max_cache=99)
        self.assertFalse(marker.exists())

    def test_command_flags_cannot_create_unbounded_build_directories(self):
        storage.validate_output_paths(self.root, ['swift', 'test', '--scratch-path',
                                     '.cache/macos-build', '--cache-path=.cache/swiftpm-cache'])
        with self.assertRaises(RuntimeError):
            storage.validate_output_paths(self.root, ['swift', 'test', '--scratch-path',
                                         '.cache/phase-999'])
        with self.assertRaises(RuntimeError):
            storage.validate_output_paths(self.root, ['cargo', 'test', '--target-dir=/tmp/new'])

    def test_low_free_space_refuses_to_start(self):
        with self.assertRaisesRegex(RuntimeError, 'Free disk space'):
            storage.run_guarded(self.root, [sys.executable, '-c', 'raise SystemExit(99)'],
                                min_free=10 ** 30)

    def test_growth_during_command_stops_process_group(self):
        pidfile = self.root / 'child.pid'
        code = ('import subprocess,time,pathlib; '
                'p=subprocess.Popen(["sleep", "120"]); '
                f'pathlib.Path({str(pidfile)!r}).write_text(str(p.pid)); '
                'time.sleep(120)')
        # The first periodic measurement exceeds the budget while a child lives.
        with patch.object(storage, 'cache_bytes', side_effect=lambda _root: 100 if pidfile.exists() else 0), \
                self.assertRaises(RuntimeError):
            storage.run_guarded(self.root, [sys.executable, '-c', code],
                                min_free=0, max_cache=99, interval=0.2, cache_interval=0.1)
        pid = int(pidfile.read_text())
        status = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                                capture_output=True, text=True).stdout.strip()
        self.assertTrue(not status or status.startswith('Z'), status)

    def test_short_command_is_checked_after_exit(self):
        with patch.object(storage, 'cache_bytes', side_effect=[0, 100]), \
                self.assertRaises(RuntimeError):
            storage.run_guarded(self.root, [sys.executable, '-c', 'pass'],
                                min_free=0, max_cache=99)

    def test_exit_status_is_preserved(self):
        self.assertEqual(storage.run_guarded(self.root,
                         [sys.executable, '-c', 'raise SystemExit(7)'], min_free=0), 7)

    def test_cleanup_excludes_data_and_preserves_dirty_checkout_and_symlink(self):
        dirty = self.root / '.cache/isolated/1/macos-build/checkouts/dependency'
        dirty.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(dirty)], check=True)
        (dirty / 'local-source.swift').write_text('uncommitted')
        target = self.root / 'target'
        target.mkdir()
        (target / 'object').write_text('compiled')
        runtime = self.root / '.shipios-local'
        runtime.mkdir()
        (runtime / 'workspace.json').write_text('keep')
        evidence = self.root / '.cache/evidence'
        evidence.mkdir()
        (evidence / 'test.log').write_text('keep')
        alias = self.root / '.cache/isolated/2'
        alias.symlink_to(dirty.parent, target_is_directory=True)
        with patch.object(storage.subprocess, 'check_output', return_value=''):
            storage.clean(self.root, apply=False)
            self.assertTrue(target.exists())
            storage.clean(self.root, apply=True)
        self.assertFalse(target.exists())
        self.assertTrue((dirty / 'local-source.swift').exists())
        self.assertTrue((runtime / 'workspace.json').exists())
        self.assertTrue((evidence / 'test.log').exists())
        self.assertTrue(alias.is_symlink())

    def test_clean_refuses_active_build_and_shared_lease(self):
        with patch.object(storage.subprocess, 'check_output', return_value='/bin/cargo\n'):
            with self.assertRaises(RuntimeError):
                storage.clean(self.root, apply=True)
        with storage.storage_lock(self.root):
            with self.assertRaises(RuntimeError):
                storage.clean(self.root, apply=True)

    def test_foreground_runtime_is_removed_on_success_and_compile_exception(self):
        for fail in (False, True):
            with patch('foreground_runtime.stop_host') as stop:
                try:
                    with temporary_runtime() as path:
                        (path / 'copied-agent').write_text('artifact')
                        if fail:
                            raise subprocess.CalledProcessError(1, ['swiftc'])
                except subprocess.CalledProcessError:
                    self.assertTrue(fail)
                self.assertFalse(path.exists())
                stop.assert_called_once_with(path)

    def test_term_cancellation_unwinds_foreground_runtime(self):
        code = ('import signal,sys,time\n'
                'from foreground_runtime import temporary_runtime\n'
                'signal.signal(signal.SIGTERM, lambda s,f: sys.exit(143))\n'
                'with temporary_runtime() as p:\n'
                ' print(p, flush=True)\n'
                ' time.sleep(120)\n')
        env = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent))
        with subprocess.Popen([sys.executable, '-c', code], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            path = Path(process.stdout.readline().strip())
            self.assertTrue(path.is_dir())
            process.send_signal(signal.SIGTERM)
            _, errors = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143, errors)
            self.assertFalse(path.exists())

    def test_exception_preserves_partial_test_diagnostics(self):
        output = self.root / 'evidence'
        output.mkdir()
        with patch('foreground_runtime.stop_host'), self.assertRaises(InterruptedError):
            with temporary_runtime(output) as path:
                (path / 'result.json').write_text('{"stage":"running"}')
                (path / 'test.log').write_text('started\n')
                raise InterruptedError(signal.SIGTERM)
        self.assertFalse(path.exists())
        self.assertEqual((output / 'test.log').read_text(), 'started\n')
        self.assertEqual((output / 'result.json').read_text(), '{"stage":"running"}')

    @unittest.skipUnless(sys.platform == 'darwin', 'Native host paths use macOS ps comm')
    def test_cleanup_stops_only_its_own_real_host_process(self):
        unrelated = subprocess.Popen(['/bin/sleep', '120'])
        try:
            with temporary_runtime() as path:
                binary = path / 'ShipiOSForegroundTests.app/Contents/MacOS/ShipiOSForegroundTests'
                binary.parent.mkdir(parents=True)
                shutil.copyfile('/bin/sleep', binary)
                binary.chmod(0o755)
                # A relocated Apple platform binary must become an ordinary local
                # executable before macOS will allow the fixture to launch.
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(binary)],
                               check=True, capture_output=True)
                host = subprocess.Popen([str(binary), '120'])
            self.assertEqual(host.wait(timeout=5), -signal.SIGTERM)
            self.assertIsNone(unrelated.poll())
            self.assertFalse(path.exists())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
