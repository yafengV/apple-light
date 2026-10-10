#!/usr/bin/env python3
"""Bound development storage; never automatically delete source or runtime data."""
import argparse
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
GIB = 1024 ** 3
MIN_FREE = 20 * GIB
MAX_CACHE = 64 * GIB


@contextmanager
def storage_lock(root, exclusive=False):
    cache = root / '.cache'
    if cache.is_symlink():
        raise RuntimeError('The managed cache directory must not be a symlink.')
    cache.mkdir(exist_ok=True)
    descriptor = os.open(cache / '.dev-storage.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
                        | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Development caches are in use; wait for the active run or cleanup.')
        yield
    finally:
        os.close(descriptor)


def cache_bytes(root):
    paths = [p for p in (root / 'target', root / '.cache', root / 'apps/macos/.build')
             if p.exists()]
    if not paths:
        return 0
    # SwiftPM/Xcode remove temporary files while compiling. Retry a raced sample,
    # but never accept an incomplete measurement or hide a permissions failure.
    for attempt in range(3):
        result = subprocess.run(['du', '-sk', *map(str, paths)],
                                capture_output=True, text=True)
        if result.returncode == 0:
            break
        missing_only = result.stderr.strip() and all(
            line.endswith(': No such file or directory')
            for line in result.stderr.strip().splitlines())
        if not missing_only or attempt == 2:
            raise subprocess.CalledProcessError(result.returncode, result.args,
                                                result.stdout, result.stderr)
        time.sleep(0.05)
    return sum(int(line.split()[0]) * 1024 for line in result.stdout.splitlines())


def check(root, min_free=MIN_FREE, max_cache=MAX_CACHE, measure_cache=True):
    free = shutil.disk_usage(root).free
    if free < min_free:
        raise RuntimeError(f'Free disk space {free / GIB:.1f} GiB is below '
                           f'{min_free / GIB:.1f} GiB; clean caches before continuing.')
    if measure_cache:
        used = cache_bytes(root)
        if used > max_cache:
            raise RuntimeError(f'Development caches {used / GIB:.1f} GiB exceed '
                               f'{max_cache / GIB:.1f} GiB. Run '
                               'python3 script/dev_storage.py clean --apply.')


def build_environment(root, environment):
    env = environment.copy()
    slots = [root / '.cache/isolated' / str(n) for n in (1, 2)]
    allowed_swift = [root / '.cache', *slots]
    allowed_rust = [root / 'target', *(p / 'target' for p in slots)]
    for key, default, allowed in (
        ('SHIPIOS_BUILD_CACHE_ROOT', allowed_swift[0], allowed_swift),
        ('CARGO_TARGET_DIR', allowed_rust[0], allowed_rust),
    ):
        path = Path(env.get(key, str(default))).expanduser()
        if not path.is_absolute():
            path = root / path
        # Do not let symlink aliases escape the managed project directories.
        if path.absolute() not in allowed or path.resolve() != path.absolute():
            raise RuntimeError(f'{key} must reuse one of: '
                               + ', '.join(str(p) for p in allowed))
        env[key] = str(path)
    env['CARGO_INCREMENTAL'] = '0'
    env['SHIPIOS_STORAGE_GUARDED'] = '1'
    return env


def validate_output_paths(root, command):
    slots = [root / '.cache/isolated' / str(n) for n in (1, 2)]
    allowed = {
        '--target-dir': [root / 'target', *(p / 'target' for p in slots)],
        '--scratch-path': [root / '.cache/macos-build', *(p / 'macos-build' for p in slots)],
        '--cache-path': [root / '.cache/swiftpm-cache', *(p / 'swiftpm-cache' for p in slots)],
        '-derivedDataPath': [root / '.cache/xcode-derived-data',
                             *(p / 'DerivedData' for p in slots)],
    }
    for index, argument in enumerate(command):
        key, separator, value = argument.partition('=')
        if key not in allowed:
            continue
        if not separator:
            if index + 1 >= len(command):
                raise RuntimeError(f'{key} needs a managed output path.')
            value = command[index + 1]
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = root / path
        if path.absolute() not in allowed[key] or path.resolve() != path.absolute():
            raise RuntimeError(f'{key} must reuse a fixed cache: '
                               + ', '.join(map(str, allowed[key])))


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run_guarded(root, command, min_free=MIN_FREE, max_cache=MAX_CACHE,
                interval=5, cache_interval=60):
    with storage_lock(root):
        return _run_guarded(root, command, min_free, max_cache, interval, cache_interval)


def _run_guarded(root, command, min_free, max_cache, interval, cache_interval):
    env = build_environment(root, os.environ)
    validate_output_paths(root, command)
    check(root, min_free, max_cache)
    process = subprocess.Popen(command, cwd=root, env=env, start_new_session=True)
    previous = {}

    def interrupted(signum, _frame):
        raise InterruptedError(signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, interrupted)
    next_cache_check = time.monotonic() + cache_interval
    try:
        while process.poll() is None:
            try:
                process.wait(timeout=interval)
            except subprocess.TimeoutExpired:
                now = time.monotonic()
                measure = now >= next_cache_check
                check(root, min_free, max_cache, measure_cache=measure)
                if measure:
                    next_cache_check = time.monotonic() + cache_interval
        # A short command can exceed the budget between periodic checks.
        check(root, min_free, max_cache)
        return process.returncode
    finally:
        stop_group(process)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def cleanup_candidates(root):
    """Only known compiler caches and old agent copies; keep logs and repositories."""
    candidates = [root / 'target', root / 'apps/macos/.build']
    cache = root / '.cache'
    if cache.is_dir() and not cache.is_symlink():
        for entry in cache.iterdir():
            if not entry.is_dir() or entry.is_symlink():
                continue
            if (entry / '.rustc_info.json').is_file():
                candidates.append(entry)
            if (entry / 'macos-build').is_dir():
                candidates.extend(entry / name for name in (
                    'macos-build', 'clang-module-cache', 'swiftpm-cache'))
            if entry.name in ('macos-build', 'clang-module-cache', 'swiftpm-cache',
                              'xcode-derived-data',
                              'swift-modules', 'swift-module-cache',
                              'swiftpm-module-cache', 'archive-regression-build',
                              'archive-regression-clang', 'archive-regression-swiftpm'):
                candidates.append(entry)
            if entry.name.startswith(('verified-agent-', 'full-regression-agent-',
                                      'initial-fork-agent-', 'initial-fork-fixed-agent-')):
                candidates.append(entry / 'shipios-agent')
        isolated = cache / 'isolated'
        if isolated.is_dir() and not isolated.is_symlink():
            for slot in ('1', '2'):
                candidates.extend(isolated / slot / name for name in (
                    'target', 'macos-build', 'clang-module-cache', 'swiftpm-cache', 'DerivedData'))
    return sorted({p for p in candidates if p.exists() and not p.is_symlink()
                   and p.resolve() == p.absolute()})


def clean(root, apply=False):
    with storage_lock(root, exclusive=True):
        _clean(root, apply)


def _clean(root, apply):
    # Refuse while tools may hold caches. Never kill another development run.
    commands = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    busy = {'cargo', 'rustc', 'xcodebuild', 'swift-build', 'swift-test', 'swift-frontend',
            'ShipiOSForegroundTests'}
    if any(Path(command.strip()).name in busy for command in commands):
        raise RuntimeError('A build or test is active; wait for it to finish before cleaning.')
    for path in cleanup_candidates(root):
        modified = []
        if path.is_dir():
            for git in path.rglob('.git'):
                result = subprocess.run(['git', '-C', str(git.parent), 'status', '--porcelain'],
                                        capture_output=True, text=True)
                if result.returncode or result.stdout.strip():
                    modified.append(str(git.parent))
        if modified:
            print('Preserving modified checkout: ' + ', '.join(modified), flush=True)
            continue
        print(('Removing ' if apply else 'Would remove ') + str(path), flush=True)
        if apply:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('check')
    sub.add_parser('run').add_argument('command', nargs=argparse.REMAINDER)
    sub.add_parser('clean').add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        if args.action == 'clean':
            clean(ROOT, args.apply)
        elif args.action == 'run':
            command = args.command
            if command[:1] == ['--']:
                command = command[1:]
            if not command:
                parser.error('run needs a command after --')
            return run_guarded(ROOT, command)
        else:
            check(ROOT)
            print(f'Development storage is within budget: {cache_bytes(ROOT) / GIB:.1f} GiB '
                  f'cache, {shutil.disk_usage(ROOT).free / GIB:.1f} GiB free.')
    except InterruptedError as error:
        return 128 + int(error.args[0])
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'Storage guard: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
