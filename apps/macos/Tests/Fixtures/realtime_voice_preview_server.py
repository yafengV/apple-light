#!/usr/bin/env python3
"""Local Realtime WebSocket fixture for explicit opt-in voice preview integration tests."""

import asyncio
import base64
import json

import websockets


async def handle(socket):
    try:
        await socket.send(json.dumps({"type": "session.created"}))
        session = json.loads(await socket.recv())
        assert session["type"] == "session.update"
        assert session["session"]["audio"]["output"]["voice"] == "marin"
        await socket.send(json.dumps({"type": "session.updated"}))
        prompt = json.loads(await socket.recv())
        assert prompt["type"] == "conversation.item.create"
        response = json.loads(await socket.recv())
        assert response["type"] == "response.create"
        silence = base64.b64encode(bytes(24_000 // 5 * 2)).decode("ascii")
        await socket.send(json.dumps({"type": "response.output_audio.delta", "delta": silence}))
        await socket.send(json.dumps({"type": "response.done", "response": {
            "status": "completed", "output": [],
        }}))
        await socket.wait_closed()
    except websockets.exceptions.ConnectionClosed:
        pass


async def main():
    async with websockets.serve(handle, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        print(f"http://127.0.0.1:{port}/v1", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
