#!/usr/bin/env python3
"""Verify the local Core component against its pinned upstream checkout (Python 3.11+)."""
import argparse
import copy
import difflib
import json
from pathlib import Path
import subprocess
import tempfile
import tomllib

REVISION = '50d77959bf927293c4b5ddcca81d05331ae582ea'
REPO = Path(__file__).resolve().parent.parent
PATCHED = ['src/codex_thread.rs', 'src/lib.rs', 'src/session/mod.rs', 'src/state/turn.rs']


def toml_value(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return '[' + ', '.join(toml_value(item) for item in value) + ']'
    if isinstance(value, dict):
        return '{ ' + ', '.join(json.dumps(key) + ' = ' + toml_value(item)
                               for key, item in value.items()) + ' }'
    raise TypeError(value)


def normalized_manifest(upstream):
    original = tomllib.loads((upstream / 'core/Cargo.toml').read_text())
    workspace = tomllib.loads((upstream / 'Cargo.toml').read_text())['workspace']
    package = {key: workspace['package'][key]
               if isinstance(value, dict) and value.get('workspace') else value
               for key, value in original['package'].items()}
    package['publish'] = False
    lines = ['# Pinned upstream manifest normalized for a standalone Cargo patch.', '[package]']
    lines += [json.dumps(key) + ' = ' + toml_value(value) for key, value in package.items()]
    lines += ['', '[lib]', 'name = "codex_core"', 'path = "src/lib.rs"', 'doctest = false']

    def dependencies(section, entries):
        lines.extend(['', section])
        for key, value in entries.items():
            if isinstance(value, dict) and value.get('workspace'):
                base = copy.deepcopy(workspace['dependencies'][key])
                base = {'version': base} if isinstance(base, str) else base
                value = {**base, **{field: item for field, item in value.items()
                                   if field not in ['workspace', 'features']}}
                features = list(dict.fromkeys(base.get('features', []) + entries[key].get('features', [])))
                if features:
                    value['features'] = features
            if isinstance(value, dict) and 'path' in value:
                value = {field: item for field, item in value.items() if field not in ['path', 'version']}
                value.update(git='https://github.com/openai/codex.git', rev=REVISION)
            lines.append(json.dumps(key) + ' = ' + toml_value(value))

    dependencies('[dependencies]', original['dependencies'])
    for target, properties in original.get('target', {}).items():
        for kind, entries in properties.items():
            dependencies('[target.' + json.dumps(target) + '.' + kind + ']', entries)
    dependencies('[dev-dependencies]', original['dev-dependencies'])
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('upstream', type=Path, help='pinned Codex repository checkout or its codex-rs directory')
    parser.add_argument('--write-patch', action='store_true', help='refresh the reviewable patch before verification')
    arguments = parser.parse_args()
    upstream = arguments.upstream.resolve()
    if (upstream / 'codex-rs').is_dir():
        upstream /= 'codex-rs'
    revision = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise SystemExit(f'wrong upstream revision: {revision}')
    subprocess.run(['git', '-C', str(upstream), 'diff', '--exit-code', 'HEAD', '--', 'core', 'Cargo.toml'], check=True)
    local = REPO / 'vendor/codex-core'
    patch = REPO / 'upstream/codex-core-approval-capture.patch'
    if arguments.write_patch:
        patch.write_text(''.join(''.join(difflib.unified_diff(
            (upstream / 'core' / name).read_text().splitlines(keepends=True),
            (local / name).read_text().splitlines(keepends=True),
            fromfile='a/' + name, tofile='b/' + name)) for name in PATCHED))
    if (local / 'Cargo.toml').read_text() != normalized_manifest(upstream):
        raise SystemExit('Core manifest differs from pinned workspace normalization')
    tracked = subprocess.check_output(['git', '-C', str(upstream), 'ls-tree', '-r',
        '--name-only', 'HEAD', '--', 'core'], text=True).splitlines()
    # Git runs ls-tree relative to codex-rs; use only committed upstream files.
    originals = {name.removeprefix('core/'): upstream / name for name in tracked}
    actual = {str(path.relative_to(local)): path for path in local.rglob('*') if path.is_file()}
    extras = {'UPSTREAM_README.md', 'LICENSE', 'NOTICE'}
    if actual.keys() != originals.keys() | extras:
        raise SystemExit(f'file set changed: {actual.keys() ^ (originals.keys() | extras)}')
    with tempfile.TemporaryDirectory(prefix='shipios-core-patch-') as directory:
        replay = Path(directory)
        for name in PATCHED:
            path = replay / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(originals[name].read_bytes())
        subprocess.run(['patch', '--batch', '-p1', '-i', str(patch)], cwd=replay, check=True)
        for name, original in originals.items():
            if name in {'Cargo.toml', 'README.md'}:
                continue
            expected = replay / name if name in PATCHED else original
            if expected.read_bytes() != actual[name].read_bytes():
                raise SystemExit(f'unreviewed source/asset change: {name}')
    if actual['UPSTREAM_README.md'].read_bytes() != originals['README.md'].read_bytes():
        raise SystemExit('upstream README changed')
    for name in ['LICENSE', 'NOTICE']:
        if actual[name].read_bytes() != (upstream.parent / name).read_bytes():
            raise SystemExit(f'upstream {name} changed')
    print(f'Core {REVISION}: {len(originals)} upstream files, four-file patch and manifest verified')


if __name__ == '__main__':
    main()
