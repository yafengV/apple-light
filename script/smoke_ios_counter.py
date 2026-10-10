#!/usr/bin/env python3
"""Controlled Responses -> real Core patch -> real iOS counter verification.

No external model, credential, user project, or commit is used. This is toolchain
evidence only; A03 still requires the user's independently configured service.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sys
import threading
import time
import uuid

from smoke_codex_rpc import Client
from verify_ios_counter import ROOT, fingerprints, run

COUNTER = '''import SwiftUI

@main
struct HelloShipiOSApp: App {
    @State private var count = 0
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text(String(count)).accessibilityIdentifier("counter.value")
                Button("Increment") { count += INCREMENT }
                    .accessibilityIdentifier("counter.increment")
                Button("Reset") { count = 0 }
                    .accessibilityIdentifier("counter.reset")
            }.padding()
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', choices=['correct', 'bad-increment', 'compile-error'], required=True)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--agent', type=Path, default=ROOT / 'dist/ShipiOS.app/Contents/Helpers/shipios-agent')
    parser.add_argument('--native-verifier', action='store_true', help='Use the production Agent verification RPC instead of the development Python verifier.')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error('Evidence directory already exists; previous runs are preserved.')
    if not args.agent.is_file():
        parser.error('Build the official app/helper first.')
    output.mkdir(parents=True)
    project, data, home = (output / name for name in ('Project', 'Data', 'Home'))
    shutil.copytree(ROOT / 'fixtures/HelloShipiOS', project)
    home.mkdir()
    before = fingerprints(project)
    source = project / 'HelloShipiOSApp.swift'
    authored = COUNTER.replace('INCREMENT', '2' if args.scenario == 'bad-increment' else '1')
    if args.scenario == 'compile-error':
        authored = authored.replace('count += 1', 'count += missingCounterIncrement')
    patch = '*** Begin Patch\n*** Update File: HelloShipiOSApp.swift\n@@\n'
    patch += ''.join('-' + line + '\n' for line in source.read_text().splitlines())
    patch += ''.join('+' + line + '\n' for line in authored.splitlines()) + '*** End Patch'
    requests = []
    provider_errors = []

    class Responses(BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(payload)
            if self.path != '/v1/responses' or self.headers.get('Authorization') != 'Bearer fixture-token':
                provider_errors.append('Wrong protocol or credential source')
            if len(requests) == 1:
                item = {'type': 'custom_tool_call', 'name': 'apply_patch',
                        'call_id': 'counter-patch', 'input': patch}
            elif len(requests) == 2:
                item = {'type': 'message', 'role': 'assistant', 'id': 'counter-message',
                        'content': [{'type': 'output_text', 'text': 'Controlled counter patch complete.'}]}
            else:
                provider_errors.append('Unexpected extra provider request')
                self.send_error(500)
                return
            events = [{'type': 'response.created', 'response': {'id': 'counter-response'}},
                      {'type': 'response.output_item.done', 'item': item},
                      {'type': 'response.completed', 'response': {'id': 'counter-response',
                       'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0}}}]
            body = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n'
                           for e in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Responses)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    client = Client(args.agent.resolve(), data, project, home, ROOT / '.cache' if args.native_verifier else None)
    events = []
    manifest = {'scenario': args.scenario, 'modelEvidence': 'controlled_loopback_only',
                'agentSHA256': hashlib.sha256(args.agent.read_bytes()).hexdigest(),
                'inputSHA256': before, 'passed': False}
    try:
        client.request('initialize', {'protocolVersion': 1})
        task = str(uuid.uuid4()).upper()
        client.request('codex.thread.start', {'taskId': task,
                       'baseUrl': f'http://127.0.0.1:{server.server_port}/v1',
                       'model': 'gpt-5.4', 'apiKey': 'fixture-token'})
        client.request('codex.turn.submit', {'taskId': task, 'text': 'Implement the fixed counter acceptance contract in HelloShipiOSApp.swift. Leave tests and project settings unchanged.'})
        deadline = time.monotonic() + 60
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, 'Controlled Core patch did not finish within 60 seconds'
            message = (client.pending_events.pop(0) if client.pending_events
                       else client.messages.get(timeout=min(20, remaining)))
            assert message is not None, 'Agent closed before completing the patch'
            if message.get('method') != 'codex.event':
                continue
            assert message['params']['taskId'] == task
            event = message['params']['event']
            events.append(event)
            if event['type'] == 'apply_patch_approval_request':
                client.request('codex.turn.approve', {'taskId': task,
                    'id': event.get('approval_id') or event['call_id'],
                    'turnId': event.get('turn_id'), 'kind': 'patch', 'decision': 'allow'})
            elif event['type'] == 'error':
                raise AssertionError(event)
            elif event['type'] == 'task_complete':
                break
        assert not provider_errors, provider_errors
        assert len(requests) == 2, len(requests)
        assert any(e['type'] == 'patch_apply_begin' and e['call_id'] == 'counter-patch' for e in events)
        assert any(e['type'] == 'patch_apply_end' and e['success'] is True for e in events)
        assert source.read_text() == authored, 'Core did not apply the proposed patch'
        after = fingerprints(project)
        changed = [f for f in sorted(set(before) | set(after)) if before.get(f) != after.get(f)]
        assert changed == ['HelloShipiOSApp.swift'], changed
        manifest['changedByCore'] = changed
        manifest['outputSHA256'] = after
        (output / 'core-events.json').write_text(json.dumps(events, indent=2) + '\n')
        if args.native_verifier:
            started = client.request('run.start', {'kind': 'verify_counter'})
            deadline = time.monotonic() + 810
            while True:
                verified = client.request('run.get', {'runId': started['id']})
                if verified['status'] not in ('queued', 'running'):
                    break
                assert time.monotonic() < deadline, 'Native verification exceeded its aggregate deadline'
                time.sleep(0.1)
            result = verified['result']
            manifest['verification'] = result['verification']
            manifest['nativeRun'] = verified
            assert not result['changedInputs']
            if args.scenario == 'correct':
                assert verified['status'] == 'succeeded' and result['verification'] == 'passed'
            elif args.scenario == 'bad-increment':
                assert verified['status'] == 'failed' and result['verification'] == 'failed'
                assert result['testSummary']['failedTests'] == 1
                assert 'exactly one' in json.dumps(result['testSummary']['testFailures'])
            else:
                assert verified['status'] == 'failed' and result['verification'] == 'not_run'
                assert result['command']['exitCode'] == 65
                assert not any(step['stage'] == 'test' for step in result['steps'])
            manifest['passed'] = True
        if not args.native_verifier:
            command = [sys.executable, str(ROOT / 'script/verify_ios_counter.py'), '--project', str(project),
                       '--simulator', args.simulator, '--output', str(output / 'Validation')]
            verified = run(command, output / 'verifier.log', 720)
            manifest['verifierExitCode'] = verified['exitCode']
            assert not verified['timedOut'], 'Verification process timed out'
            result = json.loads((output / 'Validation/manifest.json').read_text())
            manifest['verification'] = result['verification']
            if args.scenario == 'correct':
                assert verified['exitCode'] == 0 and result['passed'], result
            elif args.scenario == 'bad-increment':
                assert verified['exitCode'] == 1 and not result['passed']
                assert result['failureStage'] == 'test' and result['testSummary']['failedTests'] == 1
                assert 'exactly one' in json.dumps(result['testSummary']['testFailures'])
            else:
                assert verified['exitCode'] == 1 and not result['passed']
                assert result['failureStage'] == 'build' and result['verification'] == 'not_run'
                assert len(result['steps']) == 1, 'UI tests must not run after compilation failure'
                assert 'missingCounterIncrement' in (output / 'Validation/build.log').read_text()
            assert not result['changedInputs'], 'Verification changed the source tree'
            manifest['passed'] = True
    except Exception as error:
        manifest['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            client.close()
        except Exception as error:
            manifest['closeError'] = type(error).__name__ + ': ' + str(error)
            manifest['passed'] = False
        finally:
            server.shutdown()
            server.server_close()
            (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: v for k, v in manifest.items() if 'SHA256' not in k}, indent=2))
    return 0 if manifest['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
