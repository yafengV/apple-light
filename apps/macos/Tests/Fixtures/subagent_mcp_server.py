"""Concurrent URL requests with distinct raw IDs; only local regression fixtures."""
import json
import os
import sys

pending = {}
sequence = 0


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": identifier, "result": {
            "protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
            "serverInfo": {"name": "ChildURLFixture", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": identifier, "result": {"tools": [{
            "name": "first", "inputSchema": {"type": "object"},
            "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False}}]}})
    elif method == "tools/call":
        sequence += 1
        request = "url-request-" + str(sequence)
        pending[request] = identifier
        send({"jsonrpc": "2.0", "id": request, "method": "elicitation/create", "params": {
            "mode": "url", "message": "Complete child URL verification",
            "url": "https://example.com/verify?one_time=fixture-secret", "elicitationId": request}})
    elif method is None and identifier in pending:
        call = pending.pop(identifier)
        answer = message.get("result")
        if answer is not None and os.getenv("CALL_LOG"):
            with open(os.environ["CALL_LOG"], "a") as output:
                output.write(json.dumps(answer) + "\n")
        send({"jsonrpc": "2.0", "id": call, "result": {"content": [{
            "type": "text", "text": "URL_OK " + json.dumps(answer or {"cancelled": True})}]}})
