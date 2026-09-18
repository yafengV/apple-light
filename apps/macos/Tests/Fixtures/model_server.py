"""Local-only deterministic HTTP fixture; never uses external credentials."""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == '/redirect/models':
            self.send_response(302)
            self.send_header('Location', '/v1/models')
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'data': [{'id': 'fixture-model'}]}).encode())
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        system_text = '\n'.join(m.get('content', '') for m in body['messages'] if m['role'] == 'system' and isinstance(m.get('content'), str))
        content = body['messages'][-1]['content']
        prompt = ''.join(part.get('text', '') for part in content if part.get('type') == 'text') if isinstance(content, list) else content
        if prompt == 'http-error' or prompt.startswith('file-http-error\n'):
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'credentials must never appear in user errors')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            user_index = max((i for i, m in enumerate(body['messages']) if m['role'] == 'user'), default=0)
            user_prompt = body['messages'][user_index]['content']
            tool_results = [m for m in body['messages'][user_index+1:] if m['role'] == 'tool']
            if isinstance(user_prompt, str) and user_prompt.startswith('mcp-call') and body.get('tools'):
                required = 2 if user_prompt == 'mcp-call-twice' or user_prompt.startswith('mcp-call-timeline') else 1
                if len(tool_results) < required:
                    if user_prompt.startswith('mcp-call-timeline'):
                        for text in ['**准备 ' + str(len(tool_results) + 1) + '**：', '查找 👩🏽‍💻 e\u0301。']:
                            frame = {'choices': [{'delta': {'content': text}, 'finish_reason': None}]}
                            self.wfile.write(('data: ' + json.dumps(frame, ensure_ascii=False) + '\n\n').encode())
                            self.wfile.flush()
                    alias = body['tools'][0]['function']['name']
                    call_id = 'call-' + str(len(tool_results) + 1)
                    fragments = [
                        {'index': 0, 'id': call_id, 'type': 'function', 'function': {'name': alias, 'arguments': '{"value":'}},
                        {'index': 0, 'function': {'arguments': '"hello"}'}},
                    ]
                    for fragment in fragments:
                        frame = {'choices': [{'delta': {'tool_calls': [fragment]}, 'finish_reason': None}]}
                        self.wfile.write(('data: ' + json.dumps(frame) + '\n\n').encode())
                        self.wfile.flush()
                    self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n')
                    self.wfile.write(b'data: [DONE]\n\n')
                    return
            if prompt == 'broken':
                self.wfile.write(b'data: {not json}\n\n')
                return
            chunks = ['Hello ', '\u4e16\u754c', '!']
            if system_text.startswith('Generate a pull request title and description'):
                if os.getenv('PR_REQUEST_LOG'):
                    with open(os.environ['PR_REQUEST_LOG'], 'w') as output:
                        json.dump(body, output)
                chunks = [json.dumps({'title': 'Generated PR title', 'body': '## Summary\n\nGenerated PR description.'})]
            if '<staged_diff>' in prompt:
                if os.getenv('COMMIT_REQUEST_LOG'):
                    with open(os.environ['COMMIT_REQUEST_LOG'], 'w') as output:
                        json.dump(body, output)
                chunks = [json.dumps(body['messages'], ensure_ascii=False)]
                if 'fixture-slow-commit' in system_text:
                    chunks = ['Generated subject'] + ['.'] * 100
            if isinstance(user_prompt, str) and user_prompt.startswith('mcp-call') and tool_results:
                chunks = [json.dumps(body, ensure_ascii=False)]
                if user_prompt == 'mcp-call-slow':
                    chunks = ['partial-final'] + ['.'] * 100
                if user_prompt.startswith('mcp-call-timeline'):
                    chunks = ['## 最终回答\n\n', '查找已完成。']
                    if user_prompt == 'mcp-call-timeline-goal':
                        chunks += ['\n\nSHIPIOS_GOAL_STATUS: complete']
            if prompt.startswith('slow'):
                chunks += ['.'] * 100
            if prompt in ('context', 'image-context') or prompt.startswith('file-context\n'):
                chunks = [json.dumps(body['messages'], ensure_ascii=False)]
            if prompt.endswith('plugin-context'):
                chunks = [json.dumps(body, ensure_ascii=False)]
            if '<git_diff>' in prompt:
                chunks = [json.dumps(body['messages'], ensure_ascii=False)]
            if prompt == 'goal-request':
                chunks = [json.dumps(body, ensure_ascii=False) + '\n\nSHIPIOS_GOAL_STATUS: complete']
            if prompt == 'goal-continue':
                chunks = ['第一轮仍需继续。\n\nSHIPIOS_GOAL_STATUS: continue']
            if prompt == '继续执行这个目标。根据成功标准检查当前进度，完成剩余工作并运行必要验证。':
                chunks = ['全部成功标准已经满足。\n\nSHIPIOS_GOAL_STATUS: complete']
            if prompt == 'configuration':
                chunks = [json.dumps({key: body[key] for key in ('model', 'reasoning_effort') if key in body})]
            if prompt == 'scroll-stream':
                chunks = ['## 本地滚动验收\n\n'] + [
                    f'**实时段落 {i:03d}**：这是仅在本机生成的测试内容，用于验证阅读历史时不会被新回复拉回底部。\n\n'
                    for i in range(1, 121)
                ]
            if prompt.startswith('parallel-'):
                chunks = [prompt + ':'] + ['.'] * 25
            for text in chunks:
                data = json.dumps({'choices': [{'delta': {'content': text}, 'finish_reason': None}]}, ensure_ascii=False)
                self.wfile.write(('data: ' + data + '\n\n').encode())
                self.wfile.flush()
                time.sleep(0.35 if prompt == 'scroll-stream' else 0.12 if prompt.startswith('slow') else 0.03 if 'fixture-slow-commit' in system_text else 0.015)
            if prompt != 'truncated':
                self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n')
                if body.get('stream_options', {}).get('include_usage'):
                    usage = {'choices': [], 'usage': {
                        'prompt_tokens': 42, 'completion_tokens': 7, 'total_tokens': 49,
                        'prompt_tokens_details': {'cached_tokens': 3},
                        'completion_tokens_details': {'reasoning_tokens': 2},
                    }}
                    self.wfile.write(('data: ' + json.dumps(usage) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
