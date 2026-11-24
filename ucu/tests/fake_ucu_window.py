#!/usr/bin/env python3
"""Stand-in for `ucu-window watch` in tests: logs what it gets and answers like the real one.

Every command and its exit are appended as JSON to $FAKE_WINDOW_LOG, with the time. An app counts as closed if its name
starts with "Closed", as windowless if it starts with "Empty", and as denied if it is in the request's `deny`. "Safari"
and "Google Chrome" are active, as if the user were in them. On `rest` it exits, unless it opened an app. An app with "Stuck" in its name can't move to the agent's desktop. Each line added to
$FAKE_WINDOW_REPORTS goes out as a report. Run without `watch`, it logs its arguments like the other commands.
"""
import json
import os
import sys
import threading
import time

LOG = os.environ["FAKE_WINDOW_LOG"]
REPORTS = os.environ["FAKE_WINDOW_REPORTS"]
OPEN_DELAY = 0.2  # opening an app takes a while, and the engine must not get the call before it is done
parked = set()
opened = set()  # apps it opened, which keep it running after `rest`
writing = threading.Lock()


def send(message):
    with writing:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def relay_reports():
    with open(REPORTS) as handle:
        while True:
            line = handle.readline()
            if line:
                try:
                    send(json.loads(line))
                except OSError:  # the proxy went away
                    os._exit(0)
            else:
                time.sleep(0.02)


def answer(command):
    if "open" in command:
        name = command["open"]
        if name in command["deny"]:
            state = "denied"
        elif name.startswith("Closed") and name not in opened:  # once open, it is running
            time.sleep(OPEN_DELAY)
            opened.add(name)
            state = "opened"
        elif name.startswith("Empty"):
            state = "reopened"
        else:
            state = "running"
        send({"id": command["id"], "state": state, "active": name in ("Safari", "Google Chrome")})
    elif "show" in command and "id" in command:
        send({"id": command["id"]})
    elif "park" in command and "id" in command:
        stuck = any("Stuck" in name for name in command["park"])
        fresh = not set(command["park"]) <= parked
        parked.update(command["park"])
        send({"id": command["id"], "state": "no desktop" if stuck else "parked", "moved": fresh})
    elif "situation" in command:  # where the user is: what a test wrote in ~/user.json, or nothing known
        if os.path.exists(os.path.join(os.environ["HOME"], "old-helper")):
            return  # one built before this question existed says nothing
        said = os.path.join(os.environ["HOME"], "user.json")
        known = json.load(open(said)) if os.path.exists(said) else {}
        if "detail" not in command:  # the line and the windows elsewhere go with a list only
            known = {key: value for key, value in known.items() if key not in ("line", "elsewhere")}
        send({"id": command["id"], **known})
    elif "desktop" in command:
        moved = os.path.exists(os.path.join(os.environ["HOME"], "desktop-moved"))  # another chat's desktop left
        send({"id": command["id"], "bounds": [-3840 if moved else -1920, -2400 if moved else -1200, 1920, 1200]})


def log(entry):
    with open(LOG, "a") as handle:
        handle.write(json.dumps({"at": time.time(), **entry}) + "\n")


def main():
    if sys.argv[1:] != ["watch"]:
        log({"args": sys.argv[1:]})
        if sys.argv[1:] == ["list", "Listed"]:  # as the real one lists an app's windows
            print('Listed (com.example.listed, pid 1)\n[0] "One \\"quoted\\" 1,2 3x4" main 10,40 300x200\n'
                  '[1] "Two" minimized 20,50 300x200\n[2] "Three" dialog fullscreen -1900,-1100 400x300\n'
                  '[3] "Four" 9000,9000 200x100')
            sys.exit(0)
        print(f"args: {' '.join(sys.argv[1:])}")
        sys.exit(2 if "Missing" in sys.argv else 0)
    threading.Thread(target=relay_reports, daemon=True).start()
    for line in sys.stdin:
        command = json.loads(line)
        log(command)
        answer(command)
        if "rest" in command and not opened:
            break
    log({"exited": True})


if __name__ == "__main__":
    # However it ends, even with the proxy gone and stdout broken, it skips Python's shutdown: that flushes stdout
    # while the report thread may be writing, and aborts, which macOS reports as a Python crash.
    code = 0
    try:
        main()
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else 0
    except BaseException:
        code = 1
    finally:
        try:
            with writing:
                sys.stdout.flush()
        except BaseException:
            pass
        os._exit(code)
