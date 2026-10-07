"""Loopback model fixture: actual Core spawn_agent/close_agent, no external API."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        inputs = body.get('input', [])
        users = [entry for entry in inputs if entry.get('role') == 'user']
        text = ' '.join(part.get('text', '') for part in users[-1].get('content', [])) if users else ''
        if 'closed-child-message' in text:
            reply = 'Native child history remains readable'
            item = self.message(reply)
        else:
            closing = 'parent-close:' in text
            target = text.rsplit('parent-close:', 1)[1].strip() if closing else None
            name = 'close_agent' if closing else 'spawn_agent'
            call = 'close-fixture-' + target if closing else 'spawn-fixture'
            result = next((entry for entry in inputs if entry.get('type') == 'function_call_output'
                           and entry.get('call_id') == call), None)
            if result:
                reply = 'Parent closed child' if closing else 'Parent spawned child'
                item = self.message(reply)
            else:
                discovery = next((entry for entry in reversed(inputs)
                                  if entry.get('type') == 'tool_search_output'), {})
                offered = body.get('tools', []) + discovery.get('tools', [])
                namespace = next((tool.get('name') for tool in offered if tool.get('type') == 'namespace'
                                  and any(fn.get('name') == name for fn in tool.get('tools', []))), None)
                if namespace:
                    arguments = {'target': target} if closing else {'message': 'closed-child-message', 'agent_type': 'default'}
                    item = {'type': 'function_call', 'call_id': call, 'name': name,
                            'namespace': namespace, 'arguments': json.dumps(arguments)}
                else:
                    item = {'type': 'tool_search_call', 'call_id': 'discover-' + name,
                            'execution': 'client', 'arguments': {'query': name, 'limit': 8}}
        trace = os.environ.get('SHIPIOS_CLOSED_CHILD_LOG')
        if trace:
            with open(trace, 'a', encoding='utf-8') as log:
                log.write(json.dumps({'text': text, 'item': item}) + '\n')
        response = {'id': 'closed-child-response', 'object': 'response', 'status': 'completed',
                    'output': [item], 'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}
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
        return {'type': 'message', 'role': 'assistant', 'id': 'fixture-reply',
                'content': [{'type': 'output_text', 'text': text}]}


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
