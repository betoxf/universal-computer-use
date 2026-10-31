#!/usr/bin/env python3
"""Stand-in for `ucu-window watch` in tests: logs what it gets and answers like the real one.

Every command and its exit are appended as JSON to $FAKE_WINDOW_LOG, with the time. An app counts as closed if its name
starts with "Closed", and as denied if it is in the request's `deny`. Each line added to $FAKE_WINDOW_REPORTS goes out
as a report.
"""
import json
import os
import sys
import threading
import time

LOG = os.environ["FAKE_WINDOW_LOG"]
REPORTS = os.environ["FAKE_WINDOW_REPORTS"]
OPEN_DELAY = 0.2  # opening an app takes a while, and cua_repl must not get the call before it is done


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def relay_reports():
    with open(REPORTS) as handle:
        while True:
            line = handle.readline()
            if line:
                send(json.loads(line))
            else:
                time.sleep(0.02)


def answer(command):
    if "open" in command:
        name = command["open"]
        if name in command["deny"]:
            state = "denied"
        elif name.startswith("Closed"):
            time.sleep(OPEN_DELAY)
            state = "opened"
        else:
            state = "running"
        send({"id": command["id"], "state": state})
    elif "show" in command and "id" in command:
        send({"id": command["id"]})


def log(entry):
    with open(LOG, "a") as handle:
        handle.write(json.dumps({"at": time.time(), **entry}) + "\n")


def main():
    threading.Thread(target=relay_reports, daemon=True).start()
    for line in sys.stdin:
        command = json.loads(line)
        log(command)
        answer(command)
    log({"exited": True})


if __name__ == "__main__":
    main()
