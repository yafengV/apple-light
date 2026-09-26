import http.server
import json
import os
import sys
import time

initialized = False


def result(message, path="/"):
    global initialized
    method = message.get("method")
    if method == "initialize":
        initialized = False
        return {"protocolVersion": "future" if path == "/version" else "2025-11-25",
                "capabilities": {"tools": {}}, "serverInfo": {"name": "Fixture", "version": "1"}}
    if method == "notifications/initialized":
        initialized = True
        return None
    if method == "tools/list":
        assert initialized
        second = message.get("params", {}).get("cursor") == "second"
        name = "first" if not second or path == "/duplicate" else "second"
        tool = {"name": name, "title": name.title(), "inputSchema": {"type": "object"},
                "description": json.dumps({"EXPLICIT": os.getenv("EXPLICIT"),
                                            "PASSTHROUGH": os.getenv("PASSTHROUGH"),
                                            "CODEX_HOME": os.getenv("CODEX_HOME")})}
        if os.getenv("SHIPIOS_CODEX_PROBE"):
            tool["annotations"] = {"readOnlyHint": True, "openWorldHint": False,
                                   "destructiveHint": False}
        page = {"tools": [tool]}
        if not second:
            page["nextCursor"] = "second"
        return page
    if method == "tools/call":
        params = message.get("params", {})
        if os.getenv("CALL_LOG"):
            with open(os.environ["CALL_LOG"], "a") as f:
                f.write(json.dumps(params) + "\n")
        if os.getenv("RESULT_FILE"):
            with open(os.environ["RESULT_FILE"]) as f:
                return json.load(f)
        return {"content": [{"type": "text", "text": "TOOL_OK"}],
                "structuredContent": {"name": params.get("name"), "arguments": params.get("arguments")}}
    return None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/auth":
            self.send_error(401)
            return
        if self.path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "/mcp")
            self.end_headers()
            return
        if message.get("method") != "initialize":
            needs_version = initialized or message.get("method") == "notifications/initialized"
            if self.headers.get("MCP-Session-Id") != "fixture-session" or (needs_version and self.headers.get("MCP-Protocol-Version") != "2025-11-25"):
                self.send_error(400)
                return
        value = result(message, self.path)
        if value is None:
            self.send_response(202)
            self.end_headers()
            return
        payload = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": value}).encode()
        self.send_response(200)
        if message.get("method") == "initialize":
            self.send_header("MCP-Session-Id", "fixture-session")
        if self.path == "/sse":
            self.send_header("Content-Type", "text/event-stream")
            payload = b': comment\r\ndata:\r\n\r\ndata: {"jsonrpc":"2.0","id":"ping-id","method":"ping"}\r\n\r\ndata: ' + payload + b'\r\n\r\n'
        else:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_DELETE(self):
        self.send_response(204 if self.headers.get("MCP-Session-Id") == "fixture-session" else 400)
        self.end_headers()


if sys.argv[1] == "http":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
else:
    mode = sys.argv[1]
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write(str(os.getpid()))
    for line in sys.stdin:
        message = json.loads(line)
        if mode == "stall":
            time.sleep(30)
            continue
        if mode == "malformed":
            print("not json", flush=True)
            continue
        value = result(message, "/duplicate" if mode == "duplicate" else "/")
        if value is not None:
            payload = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": value}) + "\n"
            # Deliberately fragment frames to exercise the reader's byte buffer.
            sys.stdout.write(payload[:10]); sys.stdout.flush()
            sys.stdout.write(payload[10:]); sys.stdout.flush()
