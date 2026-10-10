"""Loopback-only Core fixture; each user turn gets its own interactive call."""
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"gpt-5.4"}]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        inputs = body.get('input', [])
        user_index = max(i for i, item in enumerate(inputs) if item.get('role') == 'user')
        prompt = json.dumps(inputs[user_index])
        call_id = 'recovery-' + hashlib.sha256(prompt.encode()).hexdigest()[:16]
        answered = any(item.get('call_id') == call_id and item.get('type') in
                       ('function_call_output', 'custom_tool_call_output') for item in inputs[user_index + 1:])
        if not answered and 'patch' in prompt:
            item = {'type': 'custom_tool_call', 'call_id': call_id, 'name': 'apply_patch',
                    'input': '*** Begin Patch\n*** Add File: patch-proof.txt\n+patched\n*** End Patch'}
        elif not answered and 'approval' in prompt:
            item = {'type': 'function_call', 'call_id': call_id, 'name': 'exec_command',
                    'arguments': json.dumps({'cmd': 'printf approved > approval-proof.txt',
                        'sandbox_permissions': 'require_escalated',
                        'justification': 'Write only the isolated fixture proof after approval'})}
        elif not answered and 'question' in prompt:
            item = {'type': 'function_call', 'call_id': call_id, 'name': 'request_user_input',
                    'arguments': json.dumps({'questions': [{'id': 'credential', 'header': 'Fixture',
                        'question': 'Choose the fixture value?', 'isOther': True,
                        'options': [{'label': 'Provided value', 'description': 'Use the fixture value.'}]}]})}
        else:
            item = {'type': 'message', 'role': 'assistant', 'id': call_id + '-reply',
                    'content': [{'type': 'output_text', 'text': 'Request recovery fixture complete'}]}
        events = [{'type': 'response.created', 'response': {'id': call_id}},
                  {'type': 'response.output_item.done', 'item': item},
                  {'type': 'response.completed', 'response': {'id': call_id,
                    'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0}}}]
        data = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
