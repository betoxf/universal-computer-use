#!/usr/bin/env python3
"""Stand-in for `ucu-window watch` in tests: logs what it gets and answers like the real one.

Every command and its exit are appended as JSON to $FAKE_WINDOW_LOG, with the time. An app counts as closed if its name
starts with "Closed", as windowless if it starts with "Empty", and as denied if it is in the request's `deny`. "Safari"
and "Google Chrome" are active, as if the user were in them. On `rest` it exits, unless it opened an app. An app with
"Stuck" in its name can't move to the agent's desktop. An app comes to the front for an agent's steps unless its name
starts with "Busy" (the user is working), "Front" (it is in front already) or "Left" (the user leaves it meanwhile).
In an app whose name starts with "Typing" the user is typing whenever it is asked, and one whose name starts with
"Covered" has another window over every place in its own. An app whose name starts with "Parked" is on the agent's
desktop, where the pointer alone is enough for a scroll, and the user's app stays in front.
An app whose name starts with "Under" has a sheet over its window, which can't be the app's main window. One whose
name starts with "Elsewhere" comes to the front with the user in another of its windows.
In an app whose name starts with "Keys" the user presses a key once its first step is made. While $HOME/user-typing
exists, the user is typing and doesn't pause.
Each line added to $FAKE_WINDOW_REPORTS goes out as a report. Run without `watch`, it logs its arguments like the
other commands.
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
lent = []  # the app that is in front for an agent's steps
modes = {}  # how each app was last lent: "borrowed", "front" or "pointer"
fronts = []  # each time the server asked who is in front since an app was lent
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
    elif "borrow" in command:
        name = command["borrow"]
        state = "busy" if name.startswith("Busy") else "front" if name.startswith("Front") else "borrowed"
        # On the agent's desktop the pointer is enough for a scroll. In "Stacked…" another window of the app is over
        # the one asked for until the app comes to the front, which raises it.
        if name.startswith(("Parked", "Stacked")) and command.get("pointerOnly"):
            state = "pointer"
        modes[name] = state
        if name.startswith("Own"):  # a browser with the user's windows and the chat's own
            state = "own"
        if state not in ("busy", "own"):
            lent.append(name)
            fronts.clear()
        send({"id": command["id"], "state": state, "front": "Mail"})
    elif "giveBack" in command and "id" in command:
        took = bool(lent) and lent[-1].startswith("Took")  # the user clicked a window of it during the steps
        send({"id": command["id"], "state": "returned" if lent else "none", "taken": took})
        lent.clear()
    elif "front" in command:  # an app called "Left…" is one the user leaves while the agent works in it
        name = lent[-1] if lent else ""
        under = name.startswith("Covered") or (name.startswith("Stacked") and modes.get(name) == "pointer")
        covered = {"top": 0} if under and "at" in command else {}  # another window is there
        elsewhere = name.startswith(("Left", "Parked")) or modes.get(name) == "pointer"  # the user's app is in front
        fronts.append(command)  # a click at a place asks twice: for the step, then for the place
        typed = {"typed": True} if name.startswith("Keys") and len(fronts) > 2 else {}
        send({"id": command["id"], "front": "Mail" if elsewhere else name, **covered, **typed})
    elif "quiet" in command:
        send({"id": command["id"], "quiet": not os.path.exists(os.path.join(os.environ["HOME"], "user-typing"))})
    elif "atWork" in command:
        send({"id": command["id"], "atWork": command["atWork"].startswith("Typing")})
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
        if sys.argv[1] == "focus" and sys.argv[2].startswith(("Under", "Elsewhere")):
            token = "under=sheet" if sys.argv[2].startswith("Under") else "user=elsewhere"
            print(f'"{sys.argv[3]}" main=false fullscreen=false frame=10,20 300x200 {token}')
            sys.exit(0 if "--activate" in sys.argv else 4)  # brought to the user, it is in front of them all the same
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
