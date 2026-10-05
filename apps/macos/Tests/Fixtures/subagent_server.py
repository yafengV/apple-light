"""Loopback Responses fixture; actual Core executes its spawn_agent tool.

The fixed model replies are not evidence of a real model's delegation ability.
Child responses remain pending after the parent's response has completed.
"""
import json
import os
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        inputs = body.get('input', [])
        users = [item for item in inputs if item.get('role') == 'user']
        text = ' '.join(part.get('text', '') for part in users[-1].get('content', [])) if users else ''
        request_text = text
        if 'subagent-child-' in text or 'subagent-peer-hold' in text:
            if 'subagent-child-followup' in text or 'subagent-child-long-history' in text:
                pass
            elif 'subagent-child-complete' in text:
                gate = Path(os.environ['SHIPIOS_SUBAGENT_COMPLETE_GATE'])
                deadline = time.monotonic() + 25
                while not gate.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
            else:
                time.sleep(30)
            reply = ('子会话完整记录🙂' * 20_000 if 'subagent-child-long-history' in text else
                     'Child followup only' if 'subagent-child-followup' in text else 'Native child finished')
            item = {'type': 'message', 'role': 'assistant', 'id': 'child-reply',
                    'content': [{'type': 'output_text', 'text': reply}]}
        elif any(item.get('type') == 'function_call_output' and
                 item.get('call_id') == 'spawn-fixture-child' for item in inputs):
            output = next(item.get('output', '') for item in inputs
                          if item.get('call_id') == 'spawn-fixture-child' and
                          item.get('type') == 'function_call_output')
            result = json.loads(output) if isinstance(output, str) and output.startswith('{') else {}
            text = ('Parent finished while child continues' if result.get('agent_id') else
                    'Spawn failed: ' + str(output)[:512])
            item = {'type': 'message', 'role': 'assistant', 'id': 'parent-reply',
                    'content': [{'type': 'output_text', 'text': text}]}
        else:
            mode = 'hold' if 'subagent-parent-stop' in text else 'complete'
            item = {'type': 'function_call', 'call_id': 'spawn-fixture-child',
                    'name': 'spawn_agent', 'arguments': json.dumps({
                        'message': 'subagent-child-' + mode, 'agent_type': 'default'})}
            discovery = next((item for item in reversed(inputs)
                              if item.get('type') == 'tool_search_output'), {})
            offered = body.get('tools', []) + discovery.get('tools', [])
            namespace = next((tool.get('name') for tool in offered
                              if tool.get('type') == 'namespace' and any(
                                  function.get('name') == 'spawn_agent'
                                  for function in tool.get('tools', []))), None)
            if namespace:
                item['namespace'] = namespace
            elif not discovery:
                item = {'type': 'tool_search_call', 'call_id': 'discover-spawn-fixture',
                        'execution': 'client', 'arguments': {'query': 'spawn_agent', 'limit': 8}}
            else:
                item = {'type': 'message', 'role': 'assistant', 'id': 'missing-spawn',
                        'content': [{'type': 'output_text', 'text': 'Spawn tool was not discovered: ' +
                                     json.dumps(discovery.get('tools', []))[:512]}]}
        trace = os.environ.get('SHIPIOS_SUBAGENT_REQUEST_LOG')
        if trace:
            parts = item.get('content', [])
            reply = ' '.join(part.get('text', '') for part in parts)
            with open(trace, 'a', encoding='utf-8') as log:
                log.write(json.dumps({'text': request_text[:512], 'type': item['type'],
                                      'reply': reply[:40], 'replyLength': len(reply)}, ensure_ascii=False) + '\n')
        response = {'id': 'fixture-response', 'object': 'response', 'status': 'completed',
                    'output': [item], 'usage': {'input_tokens': 10, 'output_tokens': 5,
                                               'total_tokens': 15}}
        events = [
            {'type': 'response.created', 'response': {'id': 'fixture-response',
                                                    'status': 'in_progress', 'output': []}},
            {'type': 'response.output_item.done', 'item': item},
            {'type': 'response.completed', 'response': response},
        ]
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for event in events:
                self.wfile.write(('event: ' + event['type'] + '\ndata: ' +
                                  json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
