#!/usr/bin/env python3
"""The native messaging host of ucu's Chrome extension (chrome-extension/), which `ucu install` registers with Chrome.

Chrome starts it when the extension connects, and they talk over stdin and stdout, each message a 4-byte length and
then JSON. Each chat's ucu-proxy.py reaches it at ~/Library/Application Support/ucu/chrome.sock: one connection per
request, a line of JSON each way. It only relays, and ends when Chrome closes its end. The newest host has the socket,
so the extension starting again, or in a second Chrome profile, takes it over.
"""
import itertools
import json
import os
import socket
import struct
import sys
import threading
from pathlib import Path

SOCKET = Path.home() / "Library/Application Support/ucu/chrome.sock"
REPLY_TIMEOUT = 10  # seconds the extension has to answer
waiting = {}        # request id -> [event set on the reply, the reply]
ids = itertools.count(1)
writing = threading.Lock()


def to_chrome(message):
    data = json.dumps(message).encode()
    with writing:
        sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
        sys.stdout.buffer.flush()


def from_chrome(own):
    """Hand each reply to the connection waiting for it, until Chrome closes its end."""
    while True:
        header = sys.stdin.buffer.read(4)
        if len(header) < 4:
            break
        message = json.loads(sys.stdin.buffer.read(struct.unpack("=I", header)[0]))
        slot = waiting.pop(message.get("id"), None)
        if slot:
            slot[1] = message
            slot[0].set()
    try:
        if os.stat(SOCKET).st_ino == own:  # a newer host's socket stays
            SOCKET.unlink()
    except OSError:
        pass
    os._exit(0)


def serve(link):
    with link:
        try:
            link.settimeout(REPLY_TIMEOUT)
            request = json.loads(link.makefile().readline())
            number, slot = next(ids), [threading.Event(), None]
            waiting[number] = slot
            to_chrome({**request, "id": number})
            slot[0].wait(REPLY_TIMEOUT)
            waiting.pop(number, None)
            reply = slot[1] or {"ok": False, "error": "the extension didn't answer"}
            link.sendall((json.dumps(reply) + "\n").encode())
        except (OSError, ValueError, AttributeError):
            pass  # the chat went away, or sent something else than a request


def main():
    SOCKET.parent.mkdir(parents=True, exist_ok=True)
    SOCKET.unlink(missing_ok=True)
    os.umask(0o177)  # the socket is the user's alone
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(SOCKET))
    server.listen()
    threading.Thread(target=from_chrome, args=(os.stat(SOCKET).st_ino,), daemon=True).start()
    while True:
        link, _ = server.accept()
        threading.Thread(target=serve, args=(link,), daemon=True).start()


if __name__ == "__main__":
    main()
