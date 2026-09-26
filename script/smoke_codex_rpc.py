#!/usr/bin/env python3
"""Exercise the bundled Agent's private Codex RPC against a loopback Responses fixture."""

import json
import queue
import subprocess
import tempfile
import threading
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
        events = [
            {"type": "response.created", "response": {"id": "resp-1"}},
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message", "role": "assistant", "id": "msg-1",
                    "content": [{"type": "output_text", "text": "RPC fixture reply"}],
                },
            },
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
                "model": "gpt-5.2",
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
            assert client.request("codex.thread.stop", {"taskId": task_id})["stopped"]
            assert len(Responses.requests) == 1, Responses.requests
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
    print("PASS: bundled Codex Agent RPC turn, events, isolation, and credential cleanup")


if __name__ == "__main__":
    main()
