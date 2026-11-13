#!/usr/bin/env python3
"""Stand-in for `osascript` running native/browser.js: logs each request to $FAKE_WINDOW_LOG and answers like Safari or
Chrome, whichever the request names.

In Safari the user has window 51 with two tabs, and is viewing the second; in Chrome, window 61 with one tab. A window
ucu makes is 900 in Safari and 901 in Chrome. State between runs is kept in $FAKE_SAFARI_STATE. A URL containing
"no-javascript" fails like the browser with JavaScript from Apple Events turned off, one containing "no-script" is
a page Chrome can only reach by having its tab's address set, by ucu (`typed`) or by its extension (`sent`), and while
$HOME/window-moved exists, ucu's window has left the agent's desktop. $HOME/user-opened-tab makes the user open a tab
in ucu's window, in front of its others, and go to it, and $HOME/user-closed-window makes them close that window, each
once.
"""
import json
import os
import sys
import time

LOG = os.environ["FAKE_WINDOW_LOG"]
STATE = os.environ["FAKE_SAFARI_STATE"]
USER_WINDOWS = {
    "safari": {"window_id": 51, "visible": True, "current_tab_index": 2, "tabs": [
        {"window_id": 51, "tab_index": 1, "url": "https://example.com/a", "title": "A"},
        {"window_id": 51, "tab_index": 2, "url": "https://example.com/b", "title": "B"}]},
    "chrome": {"window_id": 61, "visible": True, "current_tab_index": 1, "tabs": [
        {"window_id": 61, "tab_index": 1, "url": "https://mail.test", "title": "Mail"}]}}
NEW_WINDOW = {"safari": 900, "chrome": 901}
NO_JAVASCRIPT = {"safari": "You must enable 'Allow JavaScript from Apple Events' in the Develop menu",
                 "chrome": "Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, "
                           "go to View > Developer > Allow JavaScript from Apple Events."}


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {name: {"windows": [window]}
                                                                  for name, window in USER_WINDOWS.items()}


def happened(event):
    """Whether the test asked for something the user does, which they then do once."""
    flag = os.path.join(os.environ["HOME"], event)
    if not os.path.exists(flag):
        return False
    os.remove(flag)
    return True


def user_acts(state, browser):
    own = next((window for window in state["windows"] if window["window_id"] == NEW_WINDOW[browser]), None)
    if own and happened("user-opened-tab"):
        own["tabs"].insert(0, {"url": "https://user.test", "id": 7})
        own["current_tab_index"] = 1
    if own and happened("user-closed-window"):
        state["windows"].remove(own)


def answer(request, state):
    op, browser = request["op"], request["browser"]
    if str(request.get("url")).find("no-javascript") >= 0:
        raise RuntimeError(NO_JAVASCRIPT[browser])
    user_acts(state, browser)
    if op == "list" and "window_id" in request:  # ucu's window as the user has it: Chrome's tabs have ids
        return [{"window_id": window["window_id"], "visible": True, "current_tab_index": window["current_tab_index"],
                 "bounds": {"x": 40, "y": 65, "width": 1280, "height": 800},
                 "tabs": [{"window_id": window["window_id"], "tab_index": index, "url": tab["url"], "title": "T",
                           **({"id": tab["id"]} if browser == "chrome" else {})}
                          for index, tab in enumerate(window["tabs"], 1)]}
                for window in state["windows"] if window["window_id"] == request["window_id"]]
    if op == "list":
        return state["windows"]
    if op == "create_window":
        state["windows"].append({"window_id": NEW_WINDOW[browser], "visible": False, "current_tab_index": 1,
                                 "tabs": []})
        return {"window_id": NEW_WINDOW[browser]}
    set_already = request.get("typed") or request.get("sent")
    if op in ("open_tab", "navigate") and "no-script" in str(request.get("url")) and not set_already:
        window = next(window for window in state["windows"] if window["window_id"] == request["window_id"])
        if op == "open_tab":
            window["tabs"].append({"url": "chrome://newtab/", "id": 100 + len(window["tabs"])})
        return {"window_id": request["window_id"], "tab_index": request.get("tab_index", len(window["tabs"])),
                "typed": True}
    if op == "navigate" and set_already:
        return {"window_id": request["window_id"], "tab_index": request["tab_index"], "url": request["url"],
                "title": "T", "loaded": True}
    if op == "open_tab":
        window = next(window for window in state["windows"] if window["window_id"] == request["window_id"])
        window["tabs"].append({"url": request["url"], "id": 100 + len(window["tabs"])})
        return {"window_id": request["window_id"], "tab_index": len(window["tabs"]), "url": request["url"],
                "title": "T", "loaded": True}
    if op == "close_window":
        state["windows"] = [window for window in state["windows"] if window["window_id"] != request["window_id"]]
    if op == "clear_window" or (op == "close_tab" and request.get("keep_window")):
        window = next(window for window in state["windows"] if window["window_id"] == request["window_id"])
        if op == "clear_window" or len(window["tabs"]) == 1:
            window["tabs"] = []
            return {"closed": True, "blank": True}
        window["tabs"].pop(request["tab_index"] - 1)
        return {"closed": True}
    if op == "select_tab":
        return {"changed": False}
    if op == "read" and request.get("what") == "interactive":
        return {"url": "https://a.test/start", "content": [
            {"ref": "c1", "tag": "a", "text": "Docs", "href": "https://a.test/docs"},
            {"ref": "c2", "tag": "input", "type": "file", "text": ""},
            {"ref": "c3", "tag": "a", "text": "Elsewhere", "href": "https://b.test/x"}]}
    if op == "upload":
        return {"uploaded": [file["name"] for file in request["files"]], "into": "input"}
    if op == "hide_window" and os.path.exists(os.path.join(os.environ["HOME"], "window-moved")):
        return {"hidden": False, "moved": True}
    return {"op": op}


def main():
    request = json.loads(sys.argv[-1])
    with open(LOG, "a") as handle:
        handle.write(json.dumps({"at": time.time(), "osascript": request}) + "\n")
    state = load()
    try:
        reply = {"ok": True, "result": answer(request, state[request["browser"]])}
    except RuntimeError as error:
        reply = {"ok": False, "error": str(error)}
    json.dump(state, open(STATE, "w"))
    print(json.dumps(reply))


if __name__ == "__main__":
    main()
