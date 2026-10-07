"""Local model-picker fixture: public capabilities, no model completions or credentials."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

with open(sys.argv[1], encoding="utf-8") as source:
    cases = json.load(source)["cases"]
rows = [{"id": row["name"], "supported_reasoning_efforts": row["efforts"],
         "default_reasoning_effort": row["defaultEffort"]} for row in cases]
log_path = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        with open(log_path, "a", encoding="utf-8") as output:
            output.write(json.dumps({"method": "GET", "path": self.path}) + "\n")
        body = json.dumps({"data": rows}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        with open(log_path, "a", encoding="utf-8") as output:
            output.write(json.dumps({"method": "POST", "path": self.path}) + "\n")
        self.send_error(405)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
