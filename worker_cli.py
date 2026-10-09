#!/usr/bin/env python3
"""Simple TCP client for talking to worker daemon."""

import argparse
import asyncio
import json
import os
import struct
import sys


async def frame_protocol():
    reader, writer = await asyncio.open_connection(args.host, args.port)

    msg = {"action": args.cmd}
    fn = getattr(args, "file", None)
    if fn:
        msg["filename"] = fn

    buf = json.dumps(msg).encode("utf-8")
    hdr = struct.pack(">I", len(buf))
    writer.write(hdr + buf)
    await writer.drain()

    print_buf = bytearray()
    try:
        while True:
            r = await asyncio.wait_for(reader.readexactly(4), timeout=5.0)
            size = int.from_bytes(r, "big")
            payload = await reader.readexactly(size)
            try:
                d = json.loads(payload.decode())
            except json.JSONDecodeError:
                continue

            if "progress" in d:
                if not args.silent:
                    print(d["progress"], flush=True)
            else:
                # Write result JSON to file or stderr so master can read it
                path = args.result_file or "/tmp/.dtx_result"
                with open(path, "w") as f:
                    json.dump(d, f)
                if not args.silent:
                    print(f"\nResult: {json.dumps(d)}", file=sys.stderr, flush=True)
                # Write return code to separate path for simple parsing
                rc_path = path + ".rc"
                with open(rc_path, "w") as f:
                    f.write(str(d.get("rc", 1)))
    except (asyncio.IncompleteReadError, ConnectionResetError):
        pass

    writer.close()


p = argparse.ArgumentParser(description="Worker client")
p.add_argument("--host", default="127.0.0.1")
p.add_argument("--port", type=int, default=9876)
p.add_argument("-r", "--result-file", help="Path to write final JSON result + .rc file")
p.add_argument("--silent", action="store_true", help="Suppress non-progress output")

sub = p.add_subparsers(dest="cmd")
sub.add_parser("ping")
sub.add_parser("status")
tc = sub.add_parser("transcode")
tc.add_argument("-f", "--file", required=True)

args = p.parse_args()
if not args.cmd:
    p.print_help()
else:
    if not args.result_file:
        import hashlib
        rid = hashlib.md5(args.host.encode()).hexdigest()[:8]
        args.result_file = f"/tmp/.dtx_result_{os.getpid()}_{rid}"
    asyncio.run(frame_protocol())
