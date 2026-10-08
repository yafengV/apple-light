"""Own local capability server for cross-model Power selection; no completions."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

with open(sys.argv[1], encoding="utf-8") as source:
    models = json.load(source)["cases"][0]["models"]
rows = [{"id": model["model"], "display_name": model["displayName"],
         "supported_reasoning_efforts": model["efforts"], "default_reasoning_effort": "medium"}
        for model in models]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def record(self, method):
        with open(sys.argv[2], "a", encoding="utf-8") as output:
            output.write(json.dumps({"method": method, "path": self.path}) + "\n")
    def do_GET(self):
        self.record("GET")
        body = json.dumps({"data": rows}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.record("POST"); self.send_error(405)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
