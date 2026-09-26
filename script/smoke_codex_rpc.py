#!/usr/bin/env python3
"""Exercise the bundled Agent's private Codex RPC against a loopback Responses fixture."""

import json
import queue
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "dist/ShipiOS.app/Contents/Helpers/shipios-agent"


class Responses(BaseHTTPRequestHandler):
    requests = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.requests.append((self.path, self.headers.get("Authorization"), body))
        request_number = len(self.requests)
        if request_number == 12:
            item = {
                "type": "function_call", "call_id": "question-call-12", "name": "request_user_input",
                "arguments": json.dumps({"questions": [{
                    "id": "credential", "header": "Credential", "question": "Enter fixture value?",
                    "isSecret": True, "isOther": True,
                    "options": [{"label": "Provided value", "description": "Use a saved value."}],
                }]}),
            }
        elif request_number == 10:
            item = {
                "type": "custom_tool_call", "name": "apply_patch", "call_id": "patch-call-10",
                "input": "*** Begin Patch\n*** Add File: patch-proof.txt\n+patched\n*** End Patch",
            }
        elif request_number in (2, 4, 6, 8):
            proof = {
                2: "approval-proof.txt", 4: "denied-proof.txt", 6: "workspace-proof.txt",
                8: "session-proof.txt",
            }[request_number]
            arguments = {"cmd": f"printf approved > {proof}"}
            if request_number != 6:
                arguments.update({
                    "sandbox_permissions": "require_escalated",
                    "justification": "Exercise the ShipiOS approval UI bridge in a fixture project",
                })
            item = {
                "type": "function_call", "call_id": f"approval-call-{request_number}", "name": "exec_command",
                "arguments": json.dumps(arguments),
            }
        else:
            item = {
                "type": "message", "role": "assistant", "id": f"msg-{request_number}",
                "content": [{"type": "output_text", "text": "RPC fixture reply"}],
            }
        events = [
            {"type": "response.created", "response": {"id": "resp-1"}},
            {"type": "response.output_item.done", "item": item},
            {
                "type": "response.completed",
                "response": {
                    "id": "resp-1",
                    "usage": {
                        "input_tokens": 0, "input_tokens_details": None,
                        "output_tokens": 0, "output_tokens_details": None,
                        "total_tokens": 0,
                    },
                },
            },
        ]
        payload = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events
        ).encode()
        if request_number == 14:
            time.sleep(4)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


class Client:
    def __init__(self, binary, data, project, home):
        self.process = subprocess.Popen(
            [str(binary), "--data-dir", str(data), "--project", str(project), "serve"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
                "CODEX_HOME": str(data / "Codex"), "LANG": "en_US.UTF-8",
                "OPENAI_API_KEY": "environment-poison-token",
            },
        )
        self.messages = queue.Queue()
        self.pending_events = []
        self.next_id = 1
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))
        self.messages.put(None)

    def request(self, method, params=None):
        identifier = self.next_id
        self.next_id += 1
        self.process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {},
        }) + "\n")
        self.process.stdin.flush()
        while True:
            message = self.messages.get(timeout=45)
            assert message is not None, self.process.stderr.read()
            if message.get("id") == identifier:
                assert "error" not in message, message
                return message["result"]
            self.pending_events.append(message)

    def next_event(self):
        if self.pending_events:
            return self.pending_events.pop(0)
        message = self.messages.get(timeout=20)
        assert message is not None, self.process.stderr.read()
        return message

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=15)
        assert self.process.returncode == 0, self.process.stderr.read()


def main():
    assert BINARY.is_file(), "Run script/build_and_run.sh --build-app first"
    with tempfile.TemporaryDirectory(prefix="shipios-codex-rpc-") as temporary:
        root = Path(temporary)
        data, project, home = (root / name for name in ("Data", "Project", "Home"))
        project.mkdir()
        home.mkdir()
        server = ThreadingHTTPServer(("127.0.0.1", 0), Responses)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = Client(BINARY, data, project, home)
        try:
            hello = client.request("initialize", {"protocolVersion": 1})
            assert hello["capabilities"]["codexResponses"] is True
            assert hello["capabilities"]["codexEventReplay"] is False
            task_id = str(uuid.uuid4()).upper()
            started = client.request("codex.thread.start", {
                "taskId": task_id,
                "baseUrl": f"http://127.0.0.1:{server.server_port}/v1",
                "model": "gpt-5.4",
                "apiKey": "fixture-token",
            })
            assert started["taskId"] == task_id
            turn = client.request("codex.turn.submit", {"taskId": task_id, "text": "Hi"})
            assert turn["turnId"]
            reply = None
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                params = message["params"]
                assert params["taskId"] == task_id
                assert params["threadId"] == started["threadId"]
                event = params["event"]
                if event["type"] == "agent_message":
                    reply = event["message"]
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert reply == "RPC fixture reply", reply
            second = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Run the approval fixture command",
            })
            assert second["turnId"]
            saw_approval = False
            saw_command_end = False
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                if event["type"] == "exec_approval_request":
                    assert event["call_id"] == "approval-call-2", event
                    assert "approval-proof.txt" in " ".join(event["command"]), event
                    approved = client.request("codex.turn.approve", {
                        "taskId": task_id,
                        "id": event.get("approval_id") or event["call_id"],
                        "turnId": event.get("turn_id"), "kind": "exec", "decision": "allow",
                    })
                    assert approved["resolved"]
                    saw_approval = True
                elif event["type"] == "exec_command_end":
                    assert event["exit_code"] == 0, event
                    saw_command_end = True
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert saw_approval and saw_command_end, (saw_approval, saw_command_end)
            assert (project / "approval-proof.txt").read_text() == "approved"
            third = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Run the denied fixture command",
            })
            assert third["turnId"]
            saw_denial = False
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                if event["type"] == "exec_approval_request":
                    assert "denied-proof.txt" in " ".join(event["command"]), event
                    denied = client.request("codex.turn.approve", {
                        "taskId": task_id,
                        "id": event.get("approval_id") or event["call_id"],
                        "turnId": event.get("turn_id"), "kind": "exec", "decision": "deny",
                    })
                    assert denied["resolved"]
                    saw_denial = True
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert saw_denial
            assert not (project / "denied-proof.txt").exists()
            fourth = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Run the workspace write fixture command",
            })
            assert fourth["turnId"]
            saw_workspace_write = False
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                if event["type"] == "exec_approval_request":
                    raise AssertionError("Workspace write unexpectedly asked for approval")
                if event["type"] == "exec_command_end":
                    assert event["exit_code"] == 0, event
                    saw_workspace_write = True
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert saw_workspace_write
            assert (project / "workspace-proof.txt").read_text() == "approved"
            fifth = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Run the session approval fixture command",
            })
            assert fifth["turnId"]
            saw_session_approval = False
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                if event["type"] == "exec_approval_request":
                    assert "session-proof.txt" in " ".join(event["command"]), event
                    result = client.request("codex.turn.approve", {
                        "taskId": task_id,
                        "id": event.get("approval_id") or event["call_id"],
                        "turnId": event.get("turn_id"), "kind": "exec",
                        "decision": "allow_for_session",
                    })
                    assert result["resolved"]
                    saw_session_approval = True
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert saw_session_approval
            assert (project / "session-proof.txt").read_text() == "approved"
            sixth = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Apply the patch fixture",
            })
            assert sixth["turnId"]
            saw_patch_begin = False
            saw_patch_end = False
            patch_event_types = []
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                patch_event_types.append(event["type"])
                if event["type"] == "patch_apply_begin":
                    assert event["call_id"] == "patch-call-10", event
                    saw_patch_begin = True
                elif event["type"] == "patch_apply_end":
                    assert event["success"] is True, event
                    saw_patch_end = True
                elif event["type"] == "apply_patch_approval_request":
                    raise AssertionError("Workspace patch unexpectedly asked for approval")
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert saw_patch_begin and saw_patch_end, (len(Responses.requests), patch_event_types)
            assert (project / "patch-proof.txt").read_text() == "patched\n"
            seventh = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Ask the structured fixture question",
            })
            assert seventh["turnId"]
            saw_question = False
            question_events = []
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                question_events.append(event)
                if event["type"] == "request_user_input":
                    assert event["call_id"] == "question-call-12", event
                    assert event["questions"][0]["id"] == "credential", event
                    answered = client.request("codex.turn.answer", {
                        "taskId": task_id, "turnId": event["turn_id"],
                        "answers": {"credential": ["private-fixture-answer-6db5"]},
                    })
                    assert answered["answered"]
                    saw_question = True
                elif event["type"] == "task_complete":
                    break
                elif event["type"] == "error":
                    raise AssertionError(event)
            assert saw_question, [event for event in question_events if event["type"] in
                ("warning", "raw_response_item", "agent_message", "task_complete")]
            eighth = client.request("codex.turn.submit", {
                "taskId": task_id, "text": "Wait for a live steering message",
            })
            assert eighth["turnId"]
            rejected = client.request("codex.turn.steer", {
                "taskId": task_id, "expectedTurnId": "wrong-turn",
                "text": "do-not-accept-this-message",
            })
            assert rejected["steered"] is False, rejected
            accepted = client.request("codex.turn.steer", {
                "taskId": task_id, "expectedTurnId": eighth["turnId"],
                "text": "steered-rpc-proof",
            })
            assert accepted["steered"] is True, accepted
            while True:
                message = client.next_event()
                if message.get("method") != "codex.event":
                    continue
                event = message["params"]["event"]
                if event["type"] == "task_complete":
                    break
                if event["type"] == "error":
                    raise AssertionError(event)
            assert client.request("codex.thread.stop", {"taskId": task_id})["stopped"]
            assert len(Responses.requests) == 15, len(Responses.requests)
            assert b"steered-rpc-proof" in Responses.requests[-1][2]
            assert b"do-not-accept-this-message" not in Responses.requests[-1][2]
            assert Responses.requests[0][:2] == ("/v1/responses", "Bearer fixture-token")
            assert b"Hi" in Responses.requests[0][2]
        finally:
            client.close()
            server.shutdown()
            server.server_close()
        codex_home = data / "Codex" / "Tasks" / task_id.lower()
        assert not (codex_home / "auth.json").exists()
        for item in codex_home.rglob("*"):
            if item.is_file():
                contents = item.read_bytes()
                assert b"fixture-token" not in contents, item
                assert b"environment-poison-token" not in contents, item
    print("PASS: bundled Codex RPC approvals, questions, steering, workspace writes, isolation, and credential cleanup")


if __name__ == "__main__":
    main()
