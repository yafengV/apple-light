"""Local-only deterministic HTTP fixture; never uses external credentials."""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    retry_attempts = 0
    review_patch_attempts = 0
    plan_patch_attempts = 0
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
        if self.path == '/v1/responses':
            request_text = json.dumps(body)
            if 'codex-terminal-error' in request_text:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"error":{"message":"fixture request rejected"}}')
                return
            if 'codex-retry' in request_text and Handler.retry_attempts == 0:
                Handler.retry_attempts += 1
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                self.wfile.write(b'event: response.created\ndata: {"type":"response.created","response":{"id":"retry-1"}}\n\n')
                self.wfile.flush()
                self.close_connection = True
                return
            if 'codex-retry' in request_text and Handler.retry_attempts == 1:
                Handler.retry_attempts += 1
                time.sleep(2)
            slow = 'slow-codex' in request_text and 'steered-inflight-proof' not in request_text
            developer_inputs = [part.get('text', '') for message in body.get('input', [])
                if message.get('role') == 'developer' for part in message.get('content', [])]
            current_developer = developer_inputs[-1] if developer_inputs else ''
            if 'codex-native-plan' in request_text and Handler.plan_patch_attempts == 0:
                Handler.plan_patch_attempts += 1
                item = {
                    'type': 'custom_tool_call', 'call_id': 'plan-write-attempt',
                    'name': 'apply_patch',
                    'input': '*** Begin Patch\n*** Add File: plan-write-proof.txt\n+must-not-write\n*** End Patch',
                }
            elif 'codex-after-plan' in request_text and 'after-plan-write-attempt' not in request_text:
                item = {
                    'type': 'custom_tool_call', 'call_id': 'after-plan-write-attempt',
                    'name': 'apply_patch',
                    'input': '*** Begin Patch\n*** Add File: after-plan-write-proof.txt\n+written-in-default-mode\n*** End Patch',
                }
            elif 'codex-plan' in request_text and 'swift-plan-call' not in request_text:
                item = {
                    'type': 'function_call', 'call_id': 'swift-plan-call',
                    'name': 'update_plan',
                    'arguments': json.dumps({'explanation': 'Inspect then verify', 'plan': [
                        {'step': 'Inspect the project', 'status': 'completed'},
                        {'step': 'Verify behavior', 'status': 'in_progress'},
                    ]}),
                }
            elif 'codex-plan' in request_text and 'swift-plan-done-call' not in request_text:
                item = {
                    'type': 'function_call', 'call_id': 'swift-plan-done-call',
                    'name': 'update_plan',
                    'arguments': json.dumps({'plan': [
                        {'step': 'Inspect the project', 'status': 'completed'},
                        {'step': 'Verify behavior', 'status': 'completed'},
                    ]}),
                }
            elif 'codex-review-readonly' in request_text and Handler.review_patch_attempts == 0:
                Handler.review_patch_attempts += 1
                item = {
                    'type': 'custom_tool_call', 'call_id': 'review-write-attempt',
                    'name': 'apply_patch',
                    'input': '*** Begin Patch\n*** Add File: review-write-proof.txt\n+must-not-write\n*** End Patch',
                }
            elif 'codex-question' in request_text and 'function_call_output' not in request_text:
                item = {
                    'type': 'function_call', 'call_id': 'swift-question-call',
                    'name': 'request_user_input',
                    'arguments': json.dumps({'questions': [{
                        'id': 'credential', 'header': 'Credential',
                        'question': 'Enter the fixture value?', 'isSecret': True, 'isOther': True,
                        'options': [{'label': 'Provided value', 'description': 'Use a saved value.'}],
                    }]}),
                }
            elif 'codex-patch' in request_text and 'custom_tool_call_output' not in request_text:
                item = {
                    'type': 'custom_tool_call', 'call_id': 'swift-patch-call',
                    'name': 'apply_patch',
                    'input': '*** Begin Patch\n*** Add File: patch-proof.txt\n+patched\n*** End Patch',
                }
            elif 'codex-approval' in request_text and 'function_call_output' not in request_text:
                item = {
                    'type': 'function_call', 'call_id': 'swift-approval-call',
                    'name': 'exec_command',
                    'arguments': json.dumps({
                        'cmd': 'printf approved > approval-proof.txt',
                        'sandbox_permissions': 'require_escalated',
                        'justification': 'Exercise the ShipiOS approval card in a fixture project',
                    }),
                }
            elif 'codex-goal-after' in request_text:
                item = {
                    'type': 'message', 'role': 'assistant', 'id': 'goal-cleared',
                    'content': [{'type': 'output_text', 'text':
                        'Goal cleared fixture reply' if '当前任务处于目标模式' not in current_developer
                        and '<collaboration_mode>' in current_developer else 'Goal leaked'}],
                }
            elif 'codex-goal-no-status' in request_text:
                item = {
                    'type': 'message', 'role': 'assistant', 'id': 'goal-no-status',
                    'content': [{'type': 'output_text', 'text': '服务未给出完成状态。'}],
                }
            elif 'codex-goal' in request_text:
                first = '当前为第 1 轮' in current_developer
                second = '当前为第 2 轮' in current_developer
                valid = '目标：\n完成 Codex 目标' in current_developer and \
                    '1. 第一轮检查' in current_developer and \
                    '2. 第二轮完成' in current_developer
                reply = ('Codex 目标第一轮仍需继续。\n\nSHIPIOS_GOAL_STATUS: continue' if first
                    else 'Codex 目标已完成。\n\nSHIPIOS_GOAL_STATUS: complete' if second
                    else 'Missing goal turn instructions') if valid else 'Missing goal definition'
                item = {
                    'type': 'message', 'role': 'assistant', 'id': 'goal-reply',
                    'content': [{'type': 'output_text', 'text': reply}],
                }
            elif 'codex-model-switch' in request_text:
                item = {
                    'type': 'message', 'role': 'assistant', 'id': 'model-selection',
                    'content': [{'type': 'output_text', 'text': json.dumps({
                        'model': body.get('model'),
                        'effort': body.get('reasoning', {}).get('effort'),
                    })}],
                }
            else:
                item = {
                    'type': 'message', 'role': 'assistant', 'id': 'msg-1',
                    'content': [{'type': 'output_text', 'text':
                        'Steered fixture reply' if 'steered-inflight-proof' in request_text
                        else 'Default mode fixture reply' if 'codex-after-plan' in request_text
                          and '# Collaboration Mode: Default' in request_text
                        else 'Plan mode fixture reply' if 'codex-native-plan' in request_text
                          and '<collaboration_mode># Plan Mode' in request_text
                        else 'Changed review reply' if 'review-snapshot-new' in request_text
                        else 'Review fixture reply' if '<git_diff>' in request_text
                        else 'Codex fixture reply'}],
                }
            events = [
                {'type': 'response.created', 'response': {'id': 'resp-1'}},
                {'type': 'response.output_item.done', 'item': item},
                {'type': 'response.completed', 'response': {
                    'id': 'resp-1', 'usage': {
                        'input_tokens': 0, 'input_tokens_details': None,
                        'output_tokens': 0, 'output_tokens_details': None,
                        'total_tokens': 0,
                    },
                }},
            ]
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            try:
                for event in events:
                    if slow and event['type'] == 'response.output_item.done':
                        time.sleep(5)
                    self.wfile.write(('event: ' + event['type'] + '\ndata: '
                        + json.dumps(event) + '\n\n').encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
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
