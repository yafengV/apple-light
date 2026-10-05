"""Loopback model replies; actual Core spawns a child and invokes its MCP tool."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        inputs = body.get('input', [])
        start = next((i for i in range(len(inputs)-1, -1, -1) if inputs[i].get('role') == 'user'), 0)
        current = inputs[start:]
        prompt = ' '.join(part.get('text', '') for part in inputs[start].get('content', []))
        if 'fixture-child-mcp' in prompt:
            if any(i.get('type') == 'function_call_output' and i.get('call_id') == 'child-mcp-call' for i in current):
                item = self.message('Child MCP complete')
            elif any(i.get('type') == 'tool_search_output' for i in current):
                item = {'type': 'function_call', 'call_id': 'child-mcp-call', 'name': 'first',
                        'namespace': 'mcp__shipios_capture', 'arguments': '{}'}
            else:
                item = {'type': 'tool_search_call', 'call_id': 'child-mcp-search', 'execution': 'client',
                        'arguments': {'query': 'shipios_capture first MCP tool', 'limit': 8}}
        elif any(i.get('type') == 'function_call_output' and i.get('call_id') == 'spawn-mcp-child' for i in current):
            item = self.message('Parent MCP fixture complete')
        else:
            discovery = next((i for i in reversed(current) if i.get('type') == 'tool_search_output'), {})
            namespace = next((tool.get('name') for tool in body.get('tools', []) + discovery.get('tools', [])
                if tool.get('type') == 'namespace' and any(function.get('name') == 'spawn_agent' for function in tool.get('tools', []))), None)
            item = ({'type': 'function_call', 'call_id': 'spawn-mcp-child', 'name': 'spawn_agent',
                     'namespace': namespace, 'arguments': json.dumps({'message': 'fixture-child-mcp', 'agent_type': 'default'})}
                    if namespace else {'type': 'tool_search_call', 'call_id': 'spawn-mcp-search', 'execution': 'client',
                                       'arguments': {'query': 'spawn_agent', 'limit': 8}})
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for event in [
            {'type': 'response.created', 'response': {'id': 'fixture', 'status': 'in_progress', 'output': []}},
            {'type': 'response.output_item.done', 'item': item},
            {'type': 'response.completed', 'response': {'id': 'fixture', 'status': 'completed', 'output': [item],
                'usage': {'input_tokens': 10, 'output_tokens': 4, 'total_tokens': 14}}},
        ]:
            try:
                self.wfile.write(('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n').encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                break

    @staticmethod
    def message(text):
        return {'type': 'message', 'id': 'reply', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text}]}


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
