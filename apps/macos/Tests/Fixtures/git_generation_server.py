"""Loopback Responses-only fixture for isolated Git text generations."""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"gpt-5.4"}]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with open(os.environ['GENERATION_REQUEST_LOG'], 'a') as output:
            output.write(json.dumps({'path': self.path, 'body': body}, ensure_ascii=False) + '\n')
        if self.path != '/v1/responses':
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"Responses only"}}')
            return
        messages = []
        for entry in body.get('input', []):
            for part in entry.get('content', []) if isinstance(entry.get('content'), list) else []:
                text = part.get('text', '')
                if '[{' in text:
                    try:
                        value, _ = json.JSONDecoder().raw_decode(text[text.index('[{'):])
                        if isinstance(value, list) and value and 'role' in value[0]:
                            messages = value
                    except (ValueError, TypeError):
                        pass
        system = '\n'.join(m.get('content', '') for m in messages if m.get('role') == 'system')
        request_text = json.dumps(body)
        if 'fixture-generation-error' in system:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"fixture generation rejected"}}')
            return
        if 'fixture-slow-generation' in system:
            time.sleep(5)
        if 'fixture-empty-generation' in system:
            text = ''
        elif 'fixture-invalid-generation' in system:
            text = 'not a JSON result'
        elif 'Generate a pull request title' in system:
            result = {'title': 'Responses PR title', 'body': '## Summary\n\nResponses PR description.'}
            if '"commitMessage"' in system:
                result['commitMessage'] = 'Responses local commit'
            text = json.dumps(result)
        elif 'fixture-echo-generation' in system:
            text = json.dumps(messages, ensure_ascii=False)
        elif not messages:
            text = 'Normal coding reply'
        else:
            text = 'Responses commit 世界'
        item = {'type': 'message', 'role': 'assistant', 'id': 'generation-message',
                'content': [{'type': 'output_text', 'text': text}]}
        if 'fixture-tool-generation' in system and 'function_call_output' not in request_text:
            item = {'type': 'function_call', 'call_id': 'forbidden-generation-tool',
                    'name': 'exec_command', 'arguments': json.dumps({
                        'cmd': "printf forbidden > generation-tool-must-not-run.txt", 'yield_time_ms': 10000})}
        events = [{'type': 'response.created', 'response': {'id': 'generation-response'}}]
        if item['type'] == 'message' and text:
            events += [
                {'type': 'response.output_item.added', 'output_index': 0, 'item': {
                    'id': item['id'], 'type': 'message', 'role': 'assistant', 'content': []}},
                {'type': 'response.output_text.delta', 'item_id': item['id'], 'output_index': 0,
                    'content_index': 0, 'delta': text[:len(text)//2]},
                {'type': 'response.output_text.delta', 'item_id': item['id'], 'output_index': 0,
                    'content_index': 0, 'delta': text[len(text)//2:]},
            ]
        events += [{'type': 'response.output_item.done', 'item': item},
                   {'type': 'response.completed', 'response': {'id': 'generation-response', 'usage': {
                       'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}}]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            for event in events:
                if 'fixture-partial-generation' in system and event['type'] == 'response.completed':
                    time.sleep(5)
                self.wfile.write(('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
                if os.getenv('GENERATION_PHASE_LOG'):
                    with open(os.environ['GENERATION_PHASE_LOG'], 'a') as output:
                        output.write(event['type'] + '\n')
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
