#!/usr/bin/env python3
"""Lightweight transcode worker daemon listening on TCP for job commands from master."""

import asyncio
import json
import os
import socket
import struct
import sys

PORT = int(os.environ.get("W_PORT", 9876))
REMOTE_TMPDIR = os.environ.get("W_REMOTE", "/dev/shm/dist_transcode")
LOG_PATH = "/tmp/.dtx_prog.txt"


class Worker:
    def __init__(self):
        self.locked = False

    async def handle(self, reader, writer):
        data = await read_frame(reader)
        if not data:
            return
        try:
            msg = json.loads(data)
            action = msg.get("action")

            if action == "ping":
                await write_frame(writer, {"ok": True, "busy": self.locked})
                return

            if action == "status":
                prog = ""
                try:
                    with open(LOG_PATH) as f:
                        prog = f.read().strip() or ""
                except Exception:
                    pass
                await write_frame(writer, {"busy": self.locked, "progress": prog})
                return

            if action == "transcode":
                fp = msg["filename"]
                stem, ext = os.path.splitext(fp)
                ext = ext[1:] if ext else "mkv"

                if self.locked:
                    await write_frame(writer, {"ok": False, "error": "worker busy"})
                    return

                self.locked = True
                await write_frame(writer, {"status": "accepted"})

                ok, rc = await run_encode(writer, fp)
                self.locked = False
                await write_frame(writer, {"ok": ok, "rc": rc})

        except json.JSONDecodeError:
            pass
        finally:
            writer.close()


async def run_encode(writer, filename):
    """Run transcode-video.rb and stream progress lines to master."""
    os.makedirs(REMOTE_TMPDIR, exist_ok=True)
    stem = os.path.splitext(filename)[0]
    cmd = ["transcode-video.rb", "-m", "av1", filename]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, cwd=REMOTE_TMPDIR,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        lines = []
        async for line in proc.stdout:
            text = line.decode(errors='replace').strip()
            if not text:
                continue
            lines.append(text)
            try:
                await write_frame(writer, {"progress": text})
            except Exception:
                pass

        await proc.wait()
        rc = proc.returncode

        with open(LOG_PATH, "w") as f:
            f.write("\n".join(lines))

        # Check if output actually exists even if rb exited non-zero
        import glob
        outputs = glob.glob(f"{REMOTE_TMPDIR}/{stem}.*")
        has_output = bool(outputs) and any(
            os.path.getsize(o) > 0 for o in outputs
        )
        ok = (rc == 0) or has_output

        # Clean up failed job artifacts from RAM disk
        if not ok:
            import shutil
            for p in glob.glob(f"{REMOTE_TMPDIR}/{stem}.*"):
                try:
                    if os.path.isdir(p):
                        shutil.rmtree(p)
                    else:
                        os.remove(p)
                except FileNotFoundError:
                    pass

        return ok, rc

    except FileNotFoundError:
        with open(LOG_PATH, "w") as f:
            f.write("transcode-video.rb not found in PATH")
        return False, 127


# ── Frame protocol: 4-byte big-endian length prefix + UTF-8 payload ─────

async def read_frame(reader):
    try:
        hdr = await reader.readexactly(4)
        size = int.from_bytes(hdr, "big")
        buf = await reader.readexactly(size)
    except (asyncio.IncompleteReadError, ConnectionResetError):
        return None
    return buf.decode("utf-8", errors="replace")


async def write_frame(writer, data):
    if isinstance(data, dict):
        text = json.dumps(data)
    else:
        text = data
    buf = text.encode("utf-8")
    header = struct.pack(">I", len(buf))  # 4-byte big-endian
    writer.write(header + buf)
    await writer.drain()


# ── Main ─────────────────────────────────

async def main():
    w = Worker()
    server = await asyncio.start_server(
        lambda r, wr: w.handle(r, wr), "", PORT)
    print(f"worker listening :{PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
