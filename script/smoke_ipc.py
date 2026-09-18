#!/usr/bin/env python3
"""Exercise the real local agent: events, cancellation, persistence, and oversized frames."""
import json
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path

root = Path(__file__).resolve().parent.parent
binary = root / "target/debug/shipios-agent"
project = root / "fixtures/HelloShipiOS"


class Client:
    def __init__(self, data):
        self.process = subprocess.Popen(
            [str(binary), "--data-dir", str(data), "--project", str(project), "serve"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.messages = queue.Queue()
        self.events = []
        self.next_id = 1
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        finally:
            self.messages.put(None)

    def request(self, method, params=None):
        identifier = self.next_id
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            message = self.messages.get(timeout=40)
            assert message is not None, "agent closed before response"
            if message.get("id") == identifier:
                assert "error" not in message, message
                return message["result"]
            self.events.append(message)

    def terminal(self, run_id):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            run = self.request("run.get", {"runId": run_id})
            if run["status"] not in ("queued", "running"):
                return run
            time.sleep(0.05)
        raise AssertionError("run did not terminate")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        assert self.process.returncode == 0, self.process.stderr.read()


with tempfile.TemporaryDirectory(prefix="shipios-ipc-") as data:
    client = Client(data)
    try:
        capabilities = client.request("initialize", {"protocolVersion": 1})["capabilities"]
        assert capabilities["modelCalls"] is False
        inspected = client.request("project.inspect")
        assert inspected["containers"] == ["HelloShipiOS.xcodeproj"]
        run = client.request("run.start", {"kind": "doctor"})
        completed = client.terminal(run["id"])
        assert completed["status"] == "succeeded", completed
        assert completed["result"]["verification"] == "not_run"
        replay = client.request("run.events", {"runId": run["id"], "afterSequence": 1})
        assert [event["sequence"] for event in replay["events"]] == [2, 3, 4]
        assert replay["nextSequence"] == 4
        report = client.request("run.report", {"runId": run["id"]})
        assert report["run"]["status"] == "succeeded"
        assert len(report["events"]) == 4
        log = client.request("artifact.get", {"runId": run["id"], "name": "stdout.log"})
        assert "Xcode" in log["text"]
        # A terminal result must immediately release the scheduler slot.
        build = client.request("run.start", {"kind": "build", "container": "HelloShipiOS.xcodeproj", "scheme": "HelloShipiOS"})
        assert client.request("run.cancel", {"runId": build["id"]})["requested"] is True
        assert client.terminal(build["id"])["status"] == "cancelled"
    finally:
        client.close()

    restored = Client(data)
    try:
        restored.request("initialize", {"protocolVersion": 1})
        runs = restored.request("run.list")
        assert {run["status"] for run in runs} == {"succeeded", "cancelled"}
        replay = restored.request("run.events", {"runId": build["id"]})
        assert replay["events"][-1]["payload"]["status"] == "cancelled"
    finally:
        restored.close()

with tempfile.TemporaryDirectory(prefix="shipios-frame-") as data:
    result = subprocess.run([str(binary), "--data-dir", data, "serve"], input="x" * 70000 + "\n", text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["error"]["code"] == -32600

print("PASS: real doctor, streamed events, replay, report, log, immediate rerun, build cancellation, restart persistence, frame limit")
