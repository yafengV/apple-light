"""Own loopback model metadata with a service default; no model completions."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

with open(sys.argv[1], encoding="utf-8") as source:
    rows = json.load(source)["models"]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def record(self, method):
        with open(sys.argv[2], "a", encoding="utf-8") as output:
            output.write(json.dumps({"method": method, "path": self.path}) + "\n")
    def do_GET(self):
        self.record("GET")
        body = json.dumps({"models": rows}).encode()
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
