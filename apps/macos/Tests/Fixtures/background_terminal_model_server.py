"""Local Responses fixture whose actual shell output can outlive its model turn."""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        text = json.dumps(body)
        prefix = 'peer' if 'background-peer' in text else 'target'
        if 'native-background-call' not in text:
            cmd = (f'printf "%s\\n" "$$" > {prefix}-pid; printf "initial-{prefix}\\n"; '
                   f'touch {prefix}-started; '
                   f'while [ ! -e {prefix}-late-release ]; do sleep 0.03; done; '
                   f'printf "late-{prefix}\\n"; '
                   f'while [ ! -e {prefix}-finish-release ]; do sleep 0.03; done; '
                   'printf "\\033[31mRED\\033[0m\\n"; exit 3')
            item = {'type': 'function_call', 'call_id': 'native-background-call',
                    'name': 'exec_command',
                    'arguments': json.dumps({'cmd': cmd, 'yield_time_ms': 1000})}
        else:
            if 'hold-background-continuation' in text:
                root = Path(os.environ['BACKGROUND_GATE_ROOT'])
                (root / 'model-waiting').touch()
                deadline = time.monotonic() + 30
                while not (root / 'model-release').exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
            item = {'type': 'message', 'id': 'native-background-reply', 'role': 'assistant',
                    'content': [{'type': 'output_text', 'text': 'Background fixture reply'}]}
        response = {'id': 'native-background-response', 'object': 'response',
                    'status': 'completed', 'output': [item],
                    'usage': {'input_tokens': 10, 'output_tokens': 4, 'total_tokens': 14}}
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            for event in [{'type': 'response.created', 'response': dict(response, output=[], status='in_progress')},
                          {'type': 'response.output_item.done', 'item': item},
                          {'type': 'response.completed', 'response': response}]:
                self.wfile.write(('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
