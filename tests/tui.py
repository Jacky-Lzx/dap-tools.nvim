#!/usr/bin/env python3
"""Exercise the independent panel against debugpy in a real PTY."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
folder = Path(tempfile.mkdtemp(prefix="dap-tools-pty-", dir="/private/tmp" if sys.platform == "darwin" else None))
(folder / "stage").write_text("starting\n")
(folder / "example.py").write_text(
    "import sys, os\n"
    "def compute(seed):\n"
    "    values = {'answer': seed + 1, 'nested': {'label': 'ok'}}\n"
    "    marker = values['answer']\n"
    "    return marker\n"
    "result = compute(40)\n"
    "print('RESULT', result, 'ARGS', sys.argv[1:], 'ENV', os.environ.get('DAP_TOOLS_CASE'))\n"
)
env = dict(os.environ, TERM="xterm-256color", DAP_TOOLS_TEST_DIR=str(folder), DAP_TOOLS_DEBUGGEE_PYTHON=sys.executable)
adapter = env.get("DAP_TOOLS_DEBUGPY_PYTHON", sys.executable)
probe = subprocess.run([adapter, "-c", "import debugpy"], capture_output=True)
if probe.returncode:
    raise SystemExit("Set DAP_TOOLS_DEBUGPY_PYTHON to the Python interpreter containing debugpy")
env["DAP_TOOLS_DEBUGPY_PYTHON"] = adapter
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
process = subprocess.Popen(
    [env.get("NVIM", "nvim"), "-u", "NONE", "-i", "NONE", "--noplugin", "-n", "-c", "luafile tests/real_tui.lua"],
    cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
)
os.close(slave)
transcript, handled = bytearray(), set()
deadline = time.monotonic() + 75
try:
    while process.poll() is None and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.025)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            transcript.extend(data)
            if b"\x1b[6n" in data:
                os.write(master, b"\x1b[1;1R")
            if b"\x1b[c" in data:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[>c" in data:
                os.write(master, b"\x1b[>0;1;0c")
        lines = (folder / "stage").read_text().splitlines()
        if len(lines) == 2 and lines[0] not in handled:
            os.write(master, json.loads(lines[1]).encode())
            handled.add(lines[0])
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
    (folder / "terminal.bin").write_bytes(transcript)
    result = (folder / "result").read_text() if (folder / "result").exists() else "No result: " + (folder / "stage").read_text()
    if process.returncode or not result.startswith("PASS"):
        print(result)
        raise SystemExit(f"PTY failed; artifacts: {folder}")
    print(result.strip())
    print(f"PTY artifacts: {folder}")
finally:
    os.close(master)
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
