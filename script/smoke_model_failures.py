#!/usr/bin/env python3
"""Bounded actual Core fault/retry checks, or loopback server for GUI acceptance."""
import argparse
import hashlib
import json
import queue
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from smoke_codex_rpc import BINARY, Client


class FaultServer(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), FaultHandler)
        self.recovered = set()
        self.release = threading.Event()
        self.requests = []


class FaultHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.startswith("/recover/"):
            self.server.recovered.add(self.path.split("/")[2])
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"gpt-5.4"}]}')

    def send_event(self, value):
        self.wfile.write(("event: " + value["type"] + "\ndata: "
                          + json.dumps(value) + "\n\n").encode())
        self.wfile.flush()

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        mode = self.path.split("/")[1]
        self.server.requests.append({"mode": mode, "at": time.monotonic(),
                                     "recovered": mode in self.server.recovered})
        fault = mode not in self.server.recovered
        if fault and mode in ("auth", "service"):
            self.send_response(401 if mode == "auth" else 503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"controlled service unavailable"}}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            if self.path.endswith("/chat/completions"):
                text = "PARTIAL_RETAINED" if fault and mode in ("truncated", "idle") else "RECOVERED_REPLY"
                self.wfile.write(("data: " + json.dumps({"choices": [{"delta": {"content": text}}]}) + "\n\n").encode())
                self.wfile.flush()
                if fault and mode in ("truncated", "idle"):
                    if mode == "idle": self.server.release.wait(120)
                    return
                self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
                return
            self.send_event({"type": "response.created", "response": {"id": str(uuid.uuid4())}})
            if fault and mode in ("truncated", "idle"):
                self.send_event({"type": "response.output_item.added", "output_index": 0,
                    "item": {"id": "partial", "type": "message", "role": "assistant", "content": []}})
                self.send_event({"type": "response.output_text.delta", "item_id": "partial",
                    "output_index": 0, "content_index": 0, "delta": "PARTIAL_RETAINED"})
                if mode == "idle":
                    self.server.release.wait(120)
                return
            self.send_event({"type": "response.output_item.done", "item": {
                "id": "reply", "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "RECOVERED_REPLY"}]}})
            self.send_event({"type": "response.completed", "response": {
                "id": "complete", "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}}})
        except (BrokenPipeError, ConnectionResetError):
            pass


def collect(client, task, turn, timeout):
    deadline = time.monotonic() + timeout
    values = []
    while time.monotonic() < deadline:
        try:
            message = client.pending_events.pop(0) if client.pending_events else client.messages.get(
                timeout=min(1, max(.01, deadline - time.monotonic())))
        except queue.Empty:
            continue
        if message is None:
            raise AssertionError("Agent exited unexpectedly")
        if message.get("method") != "codex.event":
            continue
        if message["params"]["taskId"].lower() != task:
            raise AssertionError("Events crossed task ownership")
        event = message["params"]["event"]
        if event.get("turn_id") is not None and event["turn_id"] != turn:
            continue
        values.append(event)
        if event["type"] in ("error", "task_complete", "turn_aborted"):
            return values
    raise TimeoutError("No terminal event within the 60-second acceptance limit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--agent", type=Path, default=BINARY)
    parser.add_argument("--modes", nargs="+", choices=["auth", "service", "truncated", "idle", "connection"],
                        default=["auth", "service", "truncated", "idle", "connection"])
    args = parser.parse_args()
    server = FaultServer()
    if args.serve:
        print(server.server_port, flush=True)
        try:
            server.serve_forever()
        finally:
            server.release.set(); server.server_close()
        return
    if args.output is None or args.output.exists() or not args.agent.is_file():
        parser.error("Provide a fresh --output and an existing official --agent")
    root = args.output.resolve(); root.mkdir(parents=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    manifest = {"passed": False, "realAPI": False, "results": [],
                "agentSHA256": hashlib.sha256(args.agent.read_bytes()).hexdigest(),
                "fixtureSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    client = None
    try:
        for mode in args.modes:
            case = root / mode; case.mkdir()
            project, home = case / "Project", case / "Home"
            project.mkdir(); home.mkdir()
            task = str(uuid.uuid4())
            client = Client(args.agent.resolve(), case / "Data", project, home)
            client.request("initialize", {"protocolVersion": 1})
            base = f"http://127.0.0.1:{server.server_port}/{mode}/v1"
            # Port 1 is only used for the explicit connection failure case.
            failed_base = "http://127.0.0.1:1/v1" if mode == "connection" else base
            started = client.request("codex.thread.start", {"taskId": task,
                "baseUrl": failed_base, "model": "gpt-5.4"})
            began = time.monotonic()
            submitted = client.request("codex.turn.submit", {"taskId": task, "text": "controlled failure"})
            record = {"mode": mode, "passed": False}
            manifest["results"].append(record)
            try:
                events = collect(client, task, submitted["turnId"], 60)
            finally:
                record["failureElapsedSeconds"] = time.monotonic() - began
            record["failureEvents"] = events
            assert any(e["type"] == "error" for e in events), "Fault was reported as success"
            if mode in ("truncated", "idle"):
                assert any(e.get("delta") == "PARTIAL_RETAINED" for e in events), "Partial reply lost"
            client.request("codex.thread.stop", {"taskId": task})
            server.recovered.add(mode)
            resumed = client.request("codex.thread.start", {"taskId": task, "baseUrl": base, "model": "gpt-5.4"})
            assert resumed["threadId"] == started["threadId"], "Retry lost native history"
            submitted = client.request("codex.turn.submit", {"taskId": task, "text": "explicit retry after recovery"})
            retry = collect(client, task, submitted["turnId"], 20)
            record["retryEvents"] = retry
            assert retry[-1]["type"] == "task_complete", "Retry did not complete"
            assert retry[-1].get("last_agent_message") == "RECOVERED_REPLY", "Retry reply missing"
            record.update(passed=True, sameThreadAfterRecovery=True)
            client.request("codex.thread.stop", {"taskId": task})
            client.close(); client = None
            print("PASS:", mode, round(record["failureElapsedSeconds"], 3), "seconds; same-thread retry", flush=True)
        manifest["passed"] = True
    except Exception as error:
        manifest["error"] = str(error)
        raise
    finally:
        server.release.set()
        if client is not None:
            try:
                client.request("codex.thread.stop", {"taskId": task})
            finally:
                client.close()
        server.shutdown(); server.server_close()
        manifest["requests"] = server.requests
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
