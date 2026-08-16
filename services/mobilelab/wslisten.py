"""Listen to the live websocket and print what arrives.

The gate script uses this to measure how long a reading takes to travel from a
publisher to a websocket client. The eyewitness test uses it to show live
readings on the screen.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time

import websockets

from .config import load_settings


async def listen(url: str, count: int, timeout: float, quiet: bool) -> int:
    started = time.monotonic()
    received = 0

    try:
        async with websockets.connect(url, open_timeout=timeout) as socket:
            if not quiet:
                print(f"connected to {url}", file=sys.stderr)

            while received < count:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    break
                raw = await asyncio.wait_for(socket.recv(), timeout=remaining)
                message = json.loads(raw)

                if message.get("type") != "reading":
                    continue

                received += 1
                elapsed = time.monotonic() - started
                label = "REAL" if message.get("is_real") else "SIMULATED"
                print(
                    f"[{elapsed:6.3f}s] {label:9s} "
                    f"{message.get('sensor')}/{message.get('metric')} "
                    f"= {message.get('value')} {message.get('unit') or ''} "
                    f"source={message.get('source')} "
                    f"render_hint={message.get('render_hint')}"
                )
    except TimeoutError:
        pass
    except asyncio.TimeoutError:
        pass
    except Exception as exc:
        print(f"websocket error: {exc}", file=sys.stderr)
        return 2

    if received < count:
        print(f"TIMEOUT: wanted {count} readings, received {received}", file=sys.stderr)
        return 1

    print(f"received {received} reading(s) in {time.monotonic() - started:.3f}s", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    settings = load_settings()
    parser = argparse.ArgumentParser(prog="python -m mobilelab.wslisten")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=settings.mobilelab_api_port)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    url = f"ws://{args.host}:{args.port}/ws/live"
    return asyncio.run(listen(url, args.count, args.timeout, args.quiet))


if __name__ == "__main__":
    raise SystemExit(main())
