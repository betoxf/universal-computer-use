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

In Safari a chat's tabs are in the user's window 51, each with the mark its request gave it, and a request with `own`
finds its tab by that mark, as browser.js does. $HOME/user-opened-tab there puts a tab of the user's in front of
them all, $HOME/user-closed-tab closes the chat's last one, and $HOME/page-left-site takes its mark, as a page does
that goes to another site: with "referrer" in the file it came from the chat's page, which proves the tab, and
otherwise only the agent's word does. With $HOME/no-user-window the user has no Safari window, and with
$HOME/tab-in-front the chat's tab is the one its window shows.
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


def safari_tabs(state):
    return [(window, tab) for window in state["windows"] for tab in window["tabs"]]


def user_acts_in_safari(state):
    """What the user does around a chat's tabs in their own window."""
    if os.path.exists(os.path.join(os.environ["HOME"], "no-user-window")):
        state["windows"] = [window for window in state["windows"] if window["window_id"] != 51]
    marked = [(window, tab) for window, tab in safari_tabs(state) if tab.get("mark")]
    if marked and happened("user-opened-tab"):
        marked[0][0]["tabs"].insert(0, {"url": "https://user.test", "title": "U"})
    if marked and happened("user-closed-tab"):
        marked[-1][0]["tabs"].remove(marked[-1][1])
    flag = os.path.join(os.environ["HOME"], "page-left-site")
    if marked and os.path.exists(flag):
        tab = marked[-1][1]
        tab.update(url="https://other.test/", left=open(flag).read().strip() or "silent")
        del tab["mark"]
        os.remove(flag)


def own_tab(state, own):
    """Find a chat's tab as browser.js does: by its mark, or in its old place once its page left the site."""
    for window, tab in safari_tabs(state):
        if tab.get("mark") == own["mark"]:
            return window, tab
    home = next((window for window in state["windows"] if window["window_id"] == own["window_id"]), None)
    tab = home["tabs"][own["tab_index"] - 1] if home and own["tab_index"] <= len(home["tabs"]) else None
    if not tab or "left" not in tab or len(home["tabs"]) != len(own["known"]):
        raise LostTab("Your tab can't be found: the user may have closed it. `open` the page again.", None)
    if tab["left"] != "referrer" and own.get("claim") != own["tab_index"]:
        raise LostTab(f"Your tab's page went to another site, and nothing proves which tab it is now. Tab "
                      f"{own['tab_index']} is where yours was: if it is your page, pass tab_index {own['tab_index']}.",
                      own["tab_index"])
    tab["mark"] = own["mark"]
    return home, tab


class LostTab(RuntimeError):
    def __init__(self, message, candidate):
        super().__init__(message)
        self.candidate = candidate


def where(window, tab, own):
    return {"mark": tab["mark"], "window_id": window["window_id"], "tab_index": window["tabs"].index(tab) + 1,
            "known": [other["url"] for other in window["tabs"]], "origin": "https://a.test"}


def answer_safari(request, state, reply):
    """Safari's part: a chat's tabs among the user's. Returns None for what the rest answers."""
    op = request["op"]
    user_acts_in_safari(state)
    if op == "list" and "window_id" not in request:
        return [{"window_id": window["window_id"], "visible": window.get("visible", True),
                 "current_tab_index": window["current_tab_index"],
                 "tabs": [{"window_id": window["window_id"], "tab_index": index, "url": tab["url"],
                           "title": tab.get("title", "T"),
                           **({"yours": True, "mark": tab["mark"]} if tab.get("mark") in request.get("marks", []) else {})}
                          for index, tab in enumerate(window["tabs"], 1)]} for window in state["windows"]]
    if op == "open_tab" and "window_id" not in request:
        window = next((window for window in state["windows"] if window["window_id"] == request.get("near")), None) \
            or next((window for window in state["windows"] if window.get("visible", True)), None)
        if window is None:
            window = {"window_id": NEW_WINDOW["safari"], "visible": True, "current_tab_index": 1, "tabs": []}
            state["windows"].append(window)
        tab = {"url": request["url"], "mark": request["mark"]}
        window["tabs"].append(tab)
        reply["own"] = where(window, tab, None)
        return {"window_id": window["window_id"], "tab_index": len(window["tabs"]), "url": request["url"],
                "title": "T", "loaded": True}
    if "own" not in request:  # a window of the chat's own, on the agent's desktop: a copy of a page, or one away
        window = next((window for window in state["windows"] if window["window_id"] == request.get("window_id")), None)
        if window and op == "navigate":
            window["tabs"] = [{"url": request["url"]}]
            return {"window_id": window["window_id"], "tab_index": 1, "url": request["url"], "title": "T",
                    "loaded": True}
        if window and op == "locate":
            return {"window_id": window["window_id"], "tab_index": 1, "url": window["tabs"][0]["url"], "title": "T"}
        return None
    window, tab = own_tab(state, request["own"])
    index = window["tabs"].index(tab) + 1
    request.update(window_id=window["window_id"], tab_index=index)
    if op == "close_tab":
        window["tabs"].remove(tab)
        if not window["tabs"]:
            state["windows"].remove(window)
        return {"closed": True}
    reply["own"] = where(window, tab, request["own"])
    if op == "navigate":
        tab["url"] = request["url"]
        reply["own"] = where(window, tab, request["own"])
        return {"window_id": window["window_id"], "tab_index": index, "url": request["url"], "title": "T",
                "loaded": True}
    if op == "locate":
        front = os.path.exists(os.path.join(os.environ["HOME"], "tab-in-front"))
        return {"window_id": window["window_id"], "tab_index": index, "url": tab["url"], "title": "T",
                "current": front, "visible": True, "minimized": False,
                "bounds": {"x": 40, "y": 65, "width": 1280, "height": 800}}
    return None


def user_acts(state, browser):
    own = next((window for window in state["windows"] if window["window_id"] == NEW_WINDOW[browser]), None)
    if own and happened("user-opened-tab"):
        own["tabs"].insert(0, {"url": "https://user.test", "id": 7})
        own["current_tab_index"] = 1
    if own and happened("user-closed-window"):
        state["windows"].remove(own)


def answer(request, state, reply):
    op, browser = request["op"], request["browser"]
    if str(request.get("url")).find("no-javascript") >= 0:
        raise RuntimeError(NO_JAVASCRIPT[browser])
    if browser == "safari":
        answered = answer_safari(request, state, reply)
        if answered is not None:
            return answered
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
    reply = {"ok": True}
    try:
        reply["result"] = answer(request, state[request["browser"]], reply)
    except LostTab as error:
        reply = {"ok": False, "error": str(error), "lost": {"candidate": error.candidate}}
    except RuntimeError as error:
        reply = {"ok": False, "error": str(error)}
    json.dump(state, open(STATE, "w"))
    print(json.dumps(reply))


if __name__ == "__main__":
    main()
