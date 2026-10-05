"""Fixed loopback replies; actual Core spawns and executes the child."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        inputs = body.get('input', [])
        start = next((i for i in range(len(inputs)-1, -1, -1) if inputs[i].get('role') == 'user'), 0)
        prompt = ' '.join(part.get('text', '') for part in inputs[start].get('content', []))
        current = inputs[start:]
        if 'fixture-native-child-request' in prompt:
            if any(i.get('type') in ('function_call_output', 'custom_tool_call_output') for i in current):
                item = self.message('Child approval finished')
            elif 'fixture-native-child-request-patch' in prompt:
                item = {'type': 'custom_tool_call', 'call_id': 'child-patch', 'name': 'apply_patch',
                    'input': '*** Begin Patch\n*** Add File: child-patch-proof.txt\n+patched\n*** End Patch'}
            else:
                item = {'type': 'function_call', 'call_id': 'reused-child-command', 'name': 'exec_command',
                        'arguments': json.dumps({'cmd': 'printf approved > child-approval-proof.txt',
                            'sandbox_permissions': 'require_escalated', 'justification': 'Write a temporary fixture marker'})}
        elif any(i.get('type') == 'function_call_output' and i.get('call_id') == 'spawn-approval-child' for i in current):
            item = self.message('Parent is complete')
        else:
            discovery = next((i for i in reversed(current) if i.get('type') == 'tool_search_output'), {})
            offered = body.get('tools', []) + discovery.get('tools', [])
            namespace = next((tool.get('name') for tool in offered if tool.get('type') == 'namespace' and
                any(function.get('name') == 'spawn_agent' for function in tool.get('tools', []))), None)
            if namespace:
                item = {'type': 'function_call', 'call_id': 'spawn-approval-child', 'name': 'spawn_agent',
                    'namespace': namespace, 'arguments': json.dumps({'message': 'fixture-native-child-request-patch' if 'parent-patch' in prompt else 'fixture-native-child-request', 'agent_type': 'default'})}
            else:
                item = {'type': 'tool_search_call', 'call_id': 'discover-approval-child', 'execution': 'client',
                    'arguments': {'query': 'spawn_agent', 'limit': 8}}
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
        for event in [
            {'type': 'response.created', 'response': {'id': 'fixture', 'status': 'in_progress', 'output': []}},
            {'type': 'response.output_item.done', 'item': item},
            {'type': 'response.completed', 'response': {'id': 'fixture', 'status': 'completed', 'output': [item],
                'usage': {'input_tokens': 10, 'output_tokens': 4, 'total_tokens': 14}}},
        ]:
            self.wfile.write(('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n').encode())
            self.wfile.flush()
    @staticmethod
    def message(text):
        return {'type': 'message', 'id': 'reply', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text}]}

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
