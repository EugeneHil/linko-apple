"""Throwaway signaling relay for the LNK-3 spike: forwards every text frame to all other clients.

Run: python3 -m venv .venv && .venv/bin/pip install 'websockets==15.*' && .venv/bin/python relay.py [port]
"""

import asyncio
import sys

from websockets.asyncio.server import serve

clients = set()


async def handler(ws):
    clients.add(ws)
    print(f"+ client ({len(clients)})", flush=True)
    try:
        async for message in ws:
            kind = message[:40].replace("\n", " ")
            print(f"relay {kind}...", flush=True)
            for other in list(clients):
                if other is not ws:
                    await other.send(message)
    finally:
        clients.discard(ws)
        print(f"- client ({len(clients)})", flush=True)


async def main(port):
    async with serve(handler, "0.0.0.0", port, max_size=256 * 1024):
        print(f"relay listening on {port}", flush=True)
        await asyncio.get_running_loop().create_future()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 9000))
