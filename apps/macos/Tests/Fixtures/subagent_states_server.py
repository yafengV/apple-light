"""Local Responses fixture for real Core child failure, interruption and retry."""
import json
import os
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        inputs = body.get('input', [])
        users = [entry for entry in inputs if entry.get('role') == 'user']
        text = ' '.join(part.get('text', '') for part in users[-1].get('content', [])) if users else ''
        trace = os.environ.get('SHIPIOS_CHILD_STATES_LOG')
        if trace:
            with open(trace, 'a', encoding='utf-8') as log:
                log.write(json.dumps({'text': text}) + '\n')
        if 'state-child-retry' in text:
            if 'state-child-retry-blocked' in text:
                retry_gate = Path(os.environ['SHIPIOS_CHILD_STATES_GATE']).with_suffix('.retry')
                deadline = time.monotonic() + 45
                while not retry_gate.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
            item = self.message('Child recovered on the same thread')
        elif 'state-child-' in text:
            gate = Path(os.environ['SHIPIOS_CHILD_STATES_GATE'])
            deadline = time.monotonic() + 45
            while not gate.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            if 'state-child-failure' in text:
                try:
                    self.send_response(400)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({'error': {'message': 'Fixture child failed',
                        'type': 'invalid_request_error', 'code': 'fixture_child_failure'}}).encode())
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            item = self.message('Late child response')
        elif any(entry.get('type') == 'function_call_output' and entry.get('call_id') == 'state-spawn'
                 for entry in inputs):
            item = self.message('Parent finished independently')
        else:
            discovery = next((entry for entry in reversed(inputs)
                              if entry.get('type') == 'tool_search_output'), {})
            namespace = next((tool.get('name') for tool in body.get('tools', []) + discovery.get('tools', [])
                              if tool.get('type') == 'namespace' and any(
                                  fn.get('name') == 'spawn_agent' for fn in tool.get('tools', []))), None)
            if namespace:
                item = {'type': 'function_call', 'namespace': namespace, 'name': 'spawn_agent',
                        'call_id': 'state-spawn', 'arguments': json.dumps({
                            'message': 'state-child-failure' if 'state-parent-failure' in text else 'state-child-hold',
                            'agent_type': 'default'})}
            else:
                item = {'type': 'tool_search_call', 'execution': 'client', 'call_id': 'state-discover',
                        'arguments': {'query': 'spawn_agent', 'limit': 8}}
        response = {'id': 'state-response', 'object': 'response', 'status': 'completed', 'output': [item],
                    'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}
        events = [{'type': 'response.created', 'response': {'id': response['id'], 'status': 'in_progress', 'output': []}},
                  {'type': 'response.output_item.done', 'item': item},
                  {'type': 'response.completed', 'response': response}]
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for event in events:
                self.wfile.write(('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    @staticmethod
    def message(text):
        return {'type': 'message', 'role': 'assistant', 'id': 'state-reply',
                'content': [{'type': 'output_text', 'text': text}]}


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
