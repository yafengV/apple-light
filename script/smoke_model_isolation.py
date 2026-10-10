#!/usr/bin/env python3
"""Verify app-owned Core config/auth/history against local decoys; no real API."""
import argparse
import hashlib
import json
from pathlib import Path
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from smoke_codex_rpc import BINARY, Client


def fingerprints(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--agent', type=Path, default=BINARY)
    args = parser.parse_args()
    root = args.output.resolve()
    if root.exists():
        parser.error('Evidence directory already exists; previous runs are preserved.')
    if not args.agent.is_file():
        parser.error('Build the official app first.')
    root.mkdir(parents=True)
    home, project, data, parent = [root / name for name in ('Home', 'Project', 'Data', 'ParentCodex')]
    for directory in (home, project, parent):
        directory.mkdir()
    marker = 'PERSONAL_CODEX_DECOY_MUST_NOT_LOAD'
    for directory in (home / '.codex', parent, project / '.codex'):
        directory.mkdir(exist_ok=True)
        (directory / 'config.toml').write_text(
            'model = "personal-poison-model"\n'
            '[mcp_servers.personal_poison]\ncommand = "/usr/bin/touch"\n'
            'args = [' + json.dumps(str(root / 'POISON-MCP-STARTED')) + ']\n')
        (directory / 'auth.json').write_text(json.dumps({'OPENAI_API_KEY': marker}))
        (directory / 'AGENTS.md').write_text(marker)
        skill = directory / 'skills/personal_poison'
        skill.mkdir(parents=True)
        (skill / 'SKILL.md').write_text('---\nname: personal_poison\ndescription: ' + marker + '\n---\n' + marker)
    global_skill = home / '.agents/skills/personal_poison'
    global_skill.mkdir(parents=True)
    (global_skill / 'SKILL.md').write_text('---\nname: personal_poison\ndescription: ' + marker + '\n---\n' + marker)
    (home / '.codex/.env').write_text('OPENAI_API_KEY=' + marker + '\n')
    before = {'home': fingerprints(home), 'parent': fingerprints(parent), 'project': fingerprints(project)}
    requests = []

    class Provider(BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append({'path': self.path, 'authorization': self.headers.get('Authorization'), 'body': payload})
            item = {'type': 'message', 'role': 'assistant', 'id': str(uuid.uuid4()),
                    'content': [{'type': 'output_text', 'text': 'Isolation fixture reply'}]}
            events = [{'type': 'response.created', 'response': {'id': str(uuid.uuid4())}},
                      {'type': 'response.output_item.done', 'item': item},
                      {'type': 'response.completed', 'response': {'id': str(uuid.uuid4()),
                       'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0}}}]
            wire = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(wire)))
            self.end_headers()
            self.wfile.write(wire)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    task = str(uuid.uuid4())
    client = None
    manifest = {'passed': False, 'realAPI': False, 'agentSHA256': hashlib.sha256(args.agent.read_bytes()).hexdigest()}

    def turn(text):
        client.request('codex.turn.submit', {'taskId': task, 'text': text})
        while True:
            event = client.next_event()
            if event.get('method') != 'codex.event':
                continue
            assert event['params']['taskId'].lower() == task
            value = event['params']['event']
            if value['type'] == 'error':
                raise AssertionError('Core returned an error; inspect controlled fixture evidence')
            if value['type'] == 'task_complete':
                return

    try:
        for provider, prompt in [('a', 'FIRST_SHIPIOS_ONLY_TURN'), ('b', 'SECOND_SERVICE_TURN')]:
            client = Client(args.agent.resolve(), data, project, home, parent_codex_home=parent)
            client.request('initialize', {'protocolVersion': 1})
            started = client.request('codex.thread.start', {'taskId': task,
                'baseUrl': f'http://127.0.0.1:{server.server_port}/{provider}/v1',
                'model': 'gpt-5.4', 'apiKey': f'isolation-fixture-{provider}'})
            if provider == 'a':
                original_thread = started['threadId']
            else:
                assert started['threadId'] == original_thread, 'Restart/service change lost Core thread identity'
            turn(prompt)
            client.request('codex.thread.stop', {'taskId': task})
            client.close(); client = None
        assert len(requests) == 2, 'Unexpected provider requests'
        for index, provider in enumerate(('a', 'b')):
            request = requests[index]
            assert request['path'] == f'/{provider}/v1/responses'
            assert request['authorization'] == f'Bearer isolation-fixture-{provider}', 'Credentials crossed services'
            assert request['body']['model'] == 'gpt-5.4', 'Personal model config was inherited'
            wire = json.dumps(request['body'])
            assert marker not in wire and 'personal_poison' not in wire, 'Personal skills/instructions/MCP leaked'
            assert 'environment-poison-token' not in wire
        assert 'FIRST_SHIPIOS_ONLY_TURN' in json.dumps(requests[1]['body']), 'History not restored'
        assert not (root / 'POISON-MCP-STARTED').exists(), 'Personal MCP executed'
        assert before == {'home': fingerprints(home), 'parent': fingerprints(parent), 'project': fingerprints(project)}, 'Decoy inputs were modified'
        task_home = data / 'Codex/Tasks' / task
        assert not (task_home / 'auth.json').exists()
        for file in data.rglob('*'):
            if file.is_file():
                for secret in (b'isolation-fixture-a', b'isolation-fixture-b', b'environment-poison-token', marker.encode()):
                    assert secret not in file.read_bytes(), 'Credential/decoy persisted in app data'
        manifest.update(passed=True, providerRequests=2, sameThreadAfterRestart=True,
                        credentialScope='per_service', personalInputsUnchanged=True,
                        noPersonalSkillsOrMCP=True, noPersistedCredentials=True)
    except Exception as error:
        manifest['error'] = str(error)
        raise
    finally:
        if client is not None:
            client.close()
        server.shutdown(); server.server_close()
        # Request bodies contain only controlled inputs; Authorization is never saved.
        (root / 'requests.json').write_text(json.dumps([{'path': r['path'], 'body': r['body']} for r in requests], indent=2))
        (root / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print('PASS: independent Core model/auth/history and personal configuration/skills/MCP decoy isolation')


if __name__ == '__main__':
    main()
