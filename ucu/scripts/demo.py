"""A short, real session with ucu for the README: read Calculator, work out 12 + 34, and read the answer.

  python3 -I scripts/demo.py [--cast FILE]

It starts this clone's server over stdio, as Claude Code does, sends the same MCP calls a model would, and prints each
call and the server's answer as it comes, with how long it took. Nothing is made up or edited: the pauses between calls
only give a reader time. Calculator keeps its last result, and one that is already 46 would leave the answer nothing to
change, so a session before the recording, which isn't shown, works out 7 x 6 first. With --cast it also writes what it
printed, with its timing, as an asciicast v2 recording, which `agg` (brew install agg) turns into the README's GIF:

  python3 -I scripts/demo.py --cast /tmp/ucu-demo.cast
  agg --font-size 14 --idle-time-limit 10 --last-frame-duration 4 /tmp/ucu-demo.cast assets/demo.gif

Calculator opens on the agent's private desktop, out of sight, and closes when the server ends.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SERVER = Path(__file__).resolve().parent / "ucu-proxy.py"
WIDTH, HEIGHT = 100, 44
PROMPT, DIM, RESET = "\x1b[1;32m", "\x1b[2m", "\x1b[0m"


class Recording:
    """Prints to the terminal and keeps every write with its time, for an asciicast."""

    def __init__(self):
        self.start = time.monotonic()
        self.events = []

    def write(self, text):
        text = text.replace("\n", "\r\n")
        self.events.append([round(time.monotonic() - self.start, 3), "o", text])
        sys.stdout.write(text)
        sys.stdout.flush()

    def save(self, path):
        header = {"version": 2, "width": WIDTH, "height": HEIGHT, "timestamp": int(time.time())}
        lines = [json.dumps(header)] + [json.dumps(event, ensure_ascii=False) for event in self.events]
        Path(path).write_text("\n".join(lines) + "\n")


class Client:
    def __init__(self, folder):
        self.server = subprocess.Popen([sys.executable, "-I", str(SERVER)], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=folder)
        self.last = 0

    def call(self, method, params):
        self.last += 1
        message = {"jsonrpc": "2.0", "id": self.last, "method": method, "params": params}
        self.server.stdin.write((json.dumps(message) + "\n").encode())
        self.server.stdin.flush()
        while True:
            reply = json.loads(self.server.stdout.readline())
            if reply.get("id") == self.last:
                return reply

    def tool(self, name, arguments):
        started = time.monotonic()
        result = self.call("tools/call", {"name": name, "arguments": arguments})["result"]
        text = "\n".join(part.get("text", "") for part in result["content"])
        return text, time.monotonic() - started

    def close(self):
        self.server.stdin.close()
        self.server.wait(30)


def show(screen, client, name, arguments):
    screen.write(f"{PROMPT}{name}{RESET} {json.dumps(arguments)}\n")
    text, seconds = client.tool(name, arguments)
    screen.write(f"{text.rstrip()}\n{DIM}({seconds:.1f} s){RESET}\n\n")
    return text


def prepare(folder):
    """Leave Calculator showing 7 x 6 = 42. The server quits it as it ends, and it opens again with that result."""
    client = Client(folder)
    try:
        client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "demo", "version": "1"}})
        window, _ = client.tool("look", {"app": "Calculator"})
        clear = "All Clear" if "All Clear" in window else "Clear"
        keys = [clear, "7", "Multiply", "6", "Equals"]
        client.tool("act", {"app": "Calculator", "steps": [{"do": "click", "name": key} for key in keys]})
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cast", help="also write an asciicast v2 recording to this file")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary) / "demo"  # chats are known by their folder's name
        folder.mkdir()
        prepare(str(folder))
        screen = Recording()
        client = Client(str(folder))
        try:
            client.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                       "clientInfo": {"name": "demo", "version": "1"}})
            screen.write(f"{DIM}# An MCP client calls ucu's tools; each answer below is the server's own.{RESET}\n\n")
            time.sleep(1)
            window = show(screen, client, "look", {"app": "Calculator"})
            time.sleep(2.5)
            clear = "All Clear" if "All Clear" in window else "Clear"
            keys = [clear, "1", "2", "Add", "3", "4", "Equals"]
            show(screen, client, "act", {"app": "Calculator", "steps": [{"do": "click", "name": key} for key in keys]})
            time.sleep(2)
            show(screen, client, "look", {"app": "Calculator", "find": "Edit field"})
            time.sleep(3)
        finally:
            client.close()
    if args.cast:
        screen.save(args.cast)
    return 0


if __name__ == "__main__":
    sys.exit(main())
