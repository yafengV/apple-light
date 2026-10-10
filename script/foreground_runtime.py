"""Own and remove the foreground host's disposable copied test artifacts."""
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time


def stop_host(runtime):
    binary = runtime / 'ShipiOSForegroundTests.app/Contents/MacOS/ShipiOSForegroundTests'
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    for row in rows:
        parts = row.strip().split(None, 1)
        if len(parts) != 2 or Path(parts[1]).resolve() != binary.resolve():
            continue
        pid = int(parts[0])
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            actual = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='],
                                    capture_output=True, text=True).stdout.strip()
            if not actual or Path(actual).resolve() != binary.resolve():
                break
            time.sleep(0.1)
        else:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


@contextmanager
def temporary_runtime(output=None):
    # Cleanup runs on success, compile failure, timeout, and Python exceptions.
    with tempfile.TemporaryDirectory(prefix='shipios-foreground-') as directory:
        runtime = Path(directory).resolve()
        try:
            yield runtime
        finally:
            try:
                stop_host(runtime)
            finally:
                # Keep partial diagnostics even when the main runner unwinds on TERM.
                if output is not None:
                    for name in ('result.json', 'test.log'):
                        source = runtime / name
                        if source.is_file():
                            shutil.copy2(source, output / name)
