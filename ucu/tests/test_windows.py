"""How ucu-proxy.py keeps apps out of the way, reports new windows and shares the Mac with other chats."""
import base64
import importlib.util
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_proxy import Proxy  # noqa: E402


def load_proxy():
    spec = importlib.util.spec_from_file_location("ucu_proxy_under_test", ROOT / "scripts/ucu-proxy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WatchingProxy(Proxy):
    def __init__(self, test):
        super().__init__(test)
        path = Path(self.home.name) / ".local/bin/ucu-window"
        path.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{ROOT / "tests/fake_ucu_window.py"}" "$@"\n')
        path.chmod(0o755)
        (self.tools / "osascript").write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{ROOT / "tests/fake_osascript.py"}" "$@"\n')
        (self.tools / "osascript").chmod(0o755)
        self.initialize()

    def safari(self, **arguments):
        return self.browser("safari", **arguments)

    def chrome(self, **arguments):
        return self.browser("chrome", **arguments)

    def browser(self, tool, **arguments):
        if not (Path(self.home.name) / "Library/Application Support/ucu/policy.json").exists():
            self.policy(deny=[])
        return self.request("tools/call", {"name": tool, "arguments": arguments})["result"]

    def safari_calls(self, op=None):
        return self.browser_calls("safari", op)

    def chrome_calls(self, op=None):
        return self.browser_calls("chrome", op)

    def browser_calls(self, browser, op=None):
        return [command["osascript"] for command in self.commands("osascript")
                if command["osascript"]["browser"] == browser and op in (None, command["osascript"]["op"])]

    def screencapture_args(self):
        return (Path(self.home.name) / "screencapture.args").read_text().split()

    def report(self, **fields):
        with self.window_reports.open("a") as handle:
            handle.write(json.dumps(fields) + "\n")
        time.sleep(0.2)  # the fake's turn

    def commands(self, kind):
        lines = self.window_log.read_text().splitlines() if self.window_log.exists() else []
        return [command for command in map(json.loads, lines) if kind in command]

    def texts(self, reply):
        return [item["text"] for item in reply["result"]["content"]]

    def notes(self, reply):
        return [text for text in self.texts(reply) if text.startswith("[ucu:")]


class WatchTest(unittest.TestCase):
    def test_opens_a_closed_app_hidden_before_reading_it(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Terminal"])
        reply = proxy.look("Closed App")
        self.assertEqual(proxy.commands("open")[0]["deny"], ["Terminal"])
        self.assertIn("Closed App was closed, so ucu opened it on your private desktop", proxy.notes(reply)[0])
        self.assertEqual((proxy.commands("park")[0]["park"], proxy.commands("park")[0]["onlyHidden"]),
                         (["Closed App"], True))

    def test_keeps_an_app_it_opens_hidden_without_a_desktop(self):
        proxy = WatchingProxy(self)
        self.assertIn("Closed Stuck was closed, so ucu opened it hidden", proxy.notes(proxy.look("Closed Stuck"))[0])

    def test_runs_a_shortcut_through_the_menu(self):
        proxy = WatchingProxy(self)
        proxy.look()
        result = proxy.act({"do": "click", "on": 1}, {"do": "press", "keys": "cmd+k"}, {"do": "click", "on": 1})
        self.assertFalse(result["result"]["isError"], proxy.text(result))
        self.assertEqual(proxy.commands("args")[0]["args"], ["press", "Calculator", "cmd+k"])
        self.assertEqual([entry["command"] for entry in proxy.batched()], ["click", "click"])

    def test_chooses_a_menu_command_by_its_path(self):
        proxy = WatchingProxy(self)
        proxy.look()
        result = proxy.act({"do": "menu", "text": "File > New Window"}, {"do": "click", "on": 1})
        self.assertFalse(result["result"]["isError"], proxy.text(result))
        self.assertEqual(proxy.commands("args")[0]["args"], ["menu", "Calculator", "File > New Window"])
        self.assertEqual([entry["command"] for entry in proxy.batched()], ["click"])

    def test_passes_on_what_a_menu_holds_when_the_path_is_wrong(self):
        proxy = WatchingProxy(self)
        proxy.look("Missing")
        result = proxy.act({"do": "menu", "text": "File > Nope"}, app="Missing")
        self.assertTrue(result["result"]["isError"])
        self.assertIn("Step 1 failed: args: menu Missing File > Nope", proxy.text(result))

    def test_sends_keys_for_a_shortcut_no_menu_has(self):
        proxy = WatchingProxy(self)
        proxy.look("Missing")
        result = proxy.act({"do": "press", "keys": "cmd+j"}, app="Missing")
        self.assertFalse(result["result"]["isError"], proxy.text(result))
        self.assertEqual(proxy.batched()[0], {"command": "press", "args": {"combo": "cmd+j", "app": "Missing"}})

    def test_says_when_neither_the_menu_nor_keys_take_a_shortcut(self):
        proxy = WatchingProxy(self)
        proxy.look("Missing")
        result = proxy.act({"do": "press", "keys": "cmd+k"}, app="Missing")
        self.assertTrue(result["result"]["isError"])
        self.assertIn("Step 1 failed", proxy.text(result))

    def test_never_watches_or_opens_a_denied_app(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Closed Secrets"])
        proxy.look("Closed Secrets")
        self.assertEqual(proxy.commands("watch"), [])
        self.assertEqual(proxy.commands("open"), [])

    def test_says_nothing_about_an_app_that_was_already_running(self):
        proxy = WatchingProxy(self)
        self.assertEqual(proxy.notes(proxy.look("Calculator")), [])

    def test_opens_nothing_while_the_policy_cannot_be_read(self):
        proxy = WatchingProxy(self)
        (Path(proxy.home.name) / "Library/Application Support/ucu/policy.json").unlink()
        proxy.look("Closed App")
        self.assertEqual(proxy.commands("open"), [])

    def test_moves_a_hidden_app_to_the_desktop_before_a_click_by_position(self):
        proxy = WatchingProxy(self)
        proxy.look("Closed App")
        proxy.act({"do": "click", "xy": [10, 10]}, app="Closed App")
        self.assertEqual(proxy.commands("park")[0]["park"], ["Closed App"])
        self.assertTrue(proxy.commands("park")[0]["onlyHidden"])
        self.assertEqual(proxy.batched()[0]["command"], "mouse-click")

    def test_shows_a_hidden_app_behind_the_user_without_a_desktop(self):
        proxy = WatchingProxy(self)
        proxy.look("Closed Stuck")
        proxy.act({"do": "click", "xy": [10, 10]}, app="Closed Stuck")
        self.assertEqual(proxy.commands("show")[0]["show"], ["Closed Stuck"])

    def test_leaves_alone_an_app_the_agent_never_hid(self):
        proxy = WatchingProxy(self)
        proxy.look("Calculator")
        proxy.act({"do": "click", "xy": [10, 10]})
        self.assertEqual(proxy.commands("park"), [])

    def test_moves_an_app_to_the_desktop_when_asked(self):
        proxy = WatchingProxy(self)
        self.assertIn("private desktop", proxy.text(proxy.call("move_to_desktop", app="Calculator")))
        self.assertEqual(proxy.commands("park")[0]["park"], ["Calculator"])

    def test_tells_the_agent_when_a_running_app_got_a_window(self):
        proxy = WatchingProxy(self)
        self.assertIn("had no open window", proxy.notes(proxy.look("Empty App"))[0])

    def test_leaves_the_app_alone_after_the_agent_showed_it(self):
        proxy = WatchingProxy(self)
        proxy.look("Closed App")
        proxy.call("focus_window", app="Closed App", title="x", activate=True)
        self.assertEqual(proxy.commands("allow")[0]["allow"], "Closed App")

    def test_tells_the_agent_about_a_new_window_once(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.report(event="window", app="Calculator", kind="window", title="About", text="", buttons=[], main=False)
        self.assertIn('Calculator opened a window titled "About"', proxy.notes(proxy.look())[0])
        self.assertEqual(proxy.notes(proxy.look()), [])

    def test_keeps_a_burst_of_windows_short(self):
        proxy = WatchingProxy(self)
        proxy.look()
        for index in range(6):
            proxy.report(event="window", app="Mail", kind="window", title=str(index), text="", buttons=[], main=False)
        notes = proxy.notes(proxy.look())
        self.assertEqual(len(notes), 4)
        self.assertIn("and 3 more", notes[3])

    def test_tells_the_agent_when_the_user_got_their_app_back(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.report(event="focus", app="Blender", back="Mail")
        self.assertIn("Blender came to the front", proxy.notes(proxy.look())[0])

    def test_marks_the_time_a_call_runs_and_the_apps_it_drives(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.wait_until(lambda: len(proxy.commands("busy")) == 2)  # the helper logs a moment after the reply
        self.assertEqual([command["busy"] for command in proxy.commands("busy")], [True, False])
        self.assertEqual(proxy.commands("watch")[0]["watch"], ["calculator"])

    def test_moves_the_cursor_to_each_element(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.act({"do": "click", "on": 1})
        proxy.wait_until(lambda: proxy.commands("cursorTo"))
        self.assertEqual(proxy.commands("cursorTo")[0]["cursorTo"], [120.0, 210.0])

    def test_stops_the_helper_after_the_turn_ends(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.commands("exited"))
        self.assertEqual(len(proxy.commands("rest")), 1)

    def test_starts_the_helper_again_on_the_next_turn(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.commands("exited"))
        proxy.look()
        self.assertEqual(len(proxy.commands("cursor")), 2)

    def test_keeps_the_helper_while_an_app_it_opened_runs(self):
        proxy = WatchingProxy(self)
        proxy.look("Closed App")
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.commands("rest"))
        time.sleep(6)  # the server checks every 5 seconds: it must not ask again, nor close the helper
        self.assertEqual((len(proxy.commands("rest")), proxy.commands("exited")), (1, []))
        proxy.look()  # the next turn works with the same helper, and can rest it again
        self.assertEqual(len(proxy.commands("cursor")), 1)
        proxy.end_turn()
        proxy.wait_until(lambda: len(proxy.commands("rest")) == 2)
        proxy.process.stdin.close()  # the chat ends
        proxy.process.wait(10)
        proxy.wait_until(lambda: proxy.commands("exited"))

    def test_works_without_the_helper(self):
        proxy = Proxy(self)
        proxy.initialize()
        self.assertFalse(proxy.look()["result"]["isError"])


class SharedMacTest(unittest.TestCase):
    def other_chat(self, proxy, pid, apps, color=None):
        folder = Path(proxy.home.name) / "Library/Application Support/ucu/sessions"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"{pid}.json").write_text(json.dumps({"who": "claude-code:website", "color": color, "apps": apps}))
        return folder / f"{pid}.json"

    def test_says_when_another_agent_is_using_an_app_once(self):
        proxy = WatchingProxy(self)
        self.other_chat(proxy, os.getpid(), {"calculator": time.time()})
        notes = proxy.notes(proxy.look())
        self.assertIn("Another agent (claude-code:website) is using Calculator", notes[0])
        self.assertEqual(proxy.notes(proxy.look()), [])

    def test_survives_a_session_file_with_anything_in_it(self):
        proxy = WatchingProxy(self)
        path = self.other_chat(proxy, os.getpid(), {})
        for junk in ("[]", "{", '{"apps": 3}', '{"apps": {"calculator": "soon"}}', '{"color": []}'):
            path.write_text(junk)
            self.assertIn("result", proxy.look())

    def test_ignores_other_apps_old_use_and_chats_that_ended(self):
        proxy = WatchingProxy(self)
        self.other_chat(proxy, os.getpid(), {"calculator": time.time() - 1000, "safari": time.time()})
        ended = self.other_chat(proxy, 999999, {"calculator": time.time()})
        self.assertEqual(proxy.notes(proxy.look()), [])
        self.assertFalse(ended.exists())

    def test_publishes_what_it_uses_and_cleans_up(self):
        proxy = WatchingProxy(self)
        proxy.look()
        files = list((Path(proxy.home.name) / "Library/Application Support/ucu/sessions").glob("*.json"))
        self.assertIn("calculator", json.loads(files[0].read_text())["apps"])
        self.assertIn("test-client", json.loads(files[0].read_text())["who"])
        proxy.process.stdin.close()
        proxy.process.wait(10)
        self.assertFalse(files[0].exists())

    def cursor_color(self, proxy):
        proxy.look()
        return proxy.commands("cursor")[0]["cursor"]

    def test_gives_the_helper_a_cursor_color_before_anything_else(self):
        proxy = WatchingProxy(self)
        color = self.cursor_color(proxy)
        self.assertRegex(color, r"^#[0-9A-F]{6}$")
        first = json.loads(proxy.window_log.read_text().splitlines()[0])
        self.assertIn("cursor", first)
        self.assertEqual(first["who"], "test-client:My-Project")
        files = list((Path(proxy.home.name) / "Library/Application Support/ucu/sessions").glob("*.json"))
        self.assertEqual(json.loads(files[0].read_text())["color"], color)

    def test_a_chat_doesnt_take_a_color_another_chat_has(self):
        taken = self.cursor_color(WatchingProxy(self))
        proxy = WatchingProxy(self)
        self.other_chat(proxy, os.getpid(), {}, color=taken)
        self.assertNotEqual(self.cursor_color(proxy), taken)

    def test_tells_the_helper_when_the_turn_ends(self):
        proxy = WatchingProxy(self)
        self.cursor_color(proxy)
        proxy.end_turn()
        deadline = time.time() + 7
        while not proxy.commands("turnEnded") and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(proxy.commands("turnEnded"))


class SafariTest(unittest.TestCase):
    def test_opens_its_tabs_in_the_users_window_behind_theirs(self):
        proxy = WatchingProxy(self)
        first = json.loads(proxy.safari(op="open", url="https://a.test")["content"][0]["text"])
        second = json.loads(proxy.safari(op="open", url="https://b.test")["content"][0]["text"])
        self.assertEqual([(tab["window_id"], tab["tab_index"]) for tab in (first, second)], [(51, 3), (51, 4)])
        self.assertEqual(proxy.safari_calls("create_window"), [])  # no window of its own
        opened = proxy.safari_calls("open_tab")
        self.assertEqual(("near" in opened[0], opened[1]["near"]), (False, 51))  # the second joins the first
        self.assertRegex(opened[0]["mark"], "^[0-9a-f]{8}-1$")
        self.assertEqual(opened[1]["mark"], opened[0]["mark"][:-1] + "2")  # each tab its own mark, of this chat's
        self.assertEqual(proxy.engine_calls(), [])  # no need for the engine

    def test_gets_safari_a_window_when_the_user_has_none(self):
        proxy = WatchingProxy(self)
        (Path(proxy.home.name) / "no-user-window").touch()
        opened = json.loads(proxy.safari(op="open", url="https://a.test")["content"][0]["text"])
        self.assertEqual((opened["window_id"], opened["tab_index"]), (900, 1))

    def test_keeps_chromes_window_when_its_tabs_close(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        self.assertEqual(json.loads(proxy.chrome(op="close")["content"][0]["text"]), {"closed": True})
        self.assertIn("call `open` first", proxy.chrome(op="read")["content"][0]["text"])
        proxy.chrome(op="open", url="https://b.test")
        self.assertEqual((len(proxy.chrome_calls("create_window")), proxy.chrome_calls("close_window")), (1, []))
        self.assertEqual([call["reuse_blank"] for call in proxy.chrome_calls("open_tab")], [True, True])

    def test_keeps_chromes_window_when_its_last_tab_closes(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.chrome(op="open", url="https://b.test")
        proxy.chrome(op="close", tab_index=2)
        self.assertFalse(proxy.chrome(op="read", tab_index=1)["isError"])  # the other tab is still its own
        self.assertEqual(json.loads(proxy.chrome(op="close", tab_index=1)["content"][0]["text"]), {"closed": True})
        self.assertEqual([call["keep_window"] for call in proxy.chrome_calls("close_tab")], [True, True])
        proxy.chrome(op="open", url="https://c.test")
        self.assertEqual(len(proxy.chrome_calls("create_window")), 1)
        self.assertEqual(proxy.chrome_calls("open_tab")[-1]["reuse_blank"], True)

    def test_closes_its_tabs_and_none_of_the_users(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="open", url="https://b.test")
        proxy.safari(op="open", url="https://c.test")
        proxy.safari(op="close", tab_index=3)  # its first
        marks = [call["mark"] for call in proxy.safari_calls("open_tab")]
        self.assertEqual(proxy.safari_calls("close_tab")[0]["own"]["mark"], marks[0])
        self.assertEqual(json.loads(proxy.safari(op="close")["content"][0]["text"]), {"closed": True})
        self.assertEqual([call["own"]["mark"] for call in proxy.safari_calls("close_tab")],
                         [marks[0], marks[1], marks[2]])
        windows = json.loads(proxy.safari(op="list")["content"][0]["text"])
        self.assertEqual([len(window["tabs"]) for window in windows], [2])  # the user's two are as they were
        self.assertIn("call `open` first", proxy.safari(op="read")["content"][0]["text"])

    def test_closes_a_tab_of_the_users_as_it_is(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="close", window_id=51, tab_index=1, allow_user_tab=True)
        call = proxy.safari_calls("close_tab")[0]
        self.assertEqual((call["window_id"], call["tab_index"], "own" in call), (51, 1, False))

    def test_tells_the_helper_the_window_is_its_own(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        self.assertEqual([(command["watch"], command["own"]) for command in proxy.commands("watch")],
                         [(["safari"], True)])
        proxy.look("Calculator")
        self.assertNotIn("own", proxy.commands("watch")[-1])  # an app like any other: its windows are the user's

    def test_acts_on_its_last_tab_by_default(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="open", url="https://b.test")
        proxy.safari(op="read", what="links")
        call = proxy.safari_calls("read")[0]
        self.assertEqual((call["own"]["window_id"], call["own"]["tab_index"], call["what"]), (51, 4, "links"))
        proxy.safari(op="read", tab_index=3)  # its other tab, by where it is
        self.assertEqual(proxy.safari_calls("read")[1]["own"]["mark"], proxy.safari_calls("open_tab")[0]["mark"])

    def test_stays_out_of_safari_when_it_is_denied(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Safari"])
        result = proxy.safari(op="list")
        self.assertTrue(result["isError"])
        self.assertIn("deny list", result["content"][0]["text"])
        self.assertEqual(proxy.safari_calls(), [])

    def test_finds_its_tab_again_among_the_users(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        (Path(proxy.home.name) / "user-opened-tab").touch()  # in front of it, so it is the fourth tab now
        self.assertFalse(proxy.safari(op="read")["isError"])
        proxy.safari(op="read")
        self.assertEqual([call["own"]["tab_index"] for call in proxy.safari_calls("read")], [3, 4])

    def test_stops_when_the_user_closed_its_tab(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        (Path(proxy.home.name) / "user-closed-tab").touch()
        gone = proxy.safari(op="click", selector="a")
        self.assertTrue(gone["isError"])
        self.assertIn("can't be found", gone["content"][0]["text"])
        self.assertIn("call `open` first", proxy.safari(op="read")["content"][0]["text"])

    def test_follows_its_tab_to_another_site_when_that_is_proven(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        (Path(proxy.home.name) / "page-left-site").write_text("referrer")  # it came there from the chat's page
        self.assertFalse(proxy.safari(op="click", selector="a")["isError"])

    def test_takes_the_agents_word_for_its_tab_when_nothing_proves_it(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        (Path(proxy.home.name) / "page-left-site").touch()
        for _ in range(2):  # however often it asks
            unproven = proxy.safari(op="click", selector="a")
            self.assertTrue(unproven["isError"])
            self.assertIn("pass tab_index 3", unproven["content"][0]["text"])
        self.assertFalse(proxy.safari(op="click", selector="a", tab_index=3)["isError"])
        self.assertEqual([call["own"].get("claim") for call in proxy.safari_calls("click")], [None, None, 3])
        self.assertFalse(proxy.safari(op="click", selector="a")["isError"])  # marked again
        self.assertNotIn("claim", proxy.safari_calls("click")[-1]["own"])

    def test_needs_a_tab_first(self):
        proxy = WatchingProxy(self)
        result = proxy.safari(op="read")
        self.assertTrue(result["isError"])
        self.assertIn("call `open` first", result["content"][0]["text"])

    def test_shows_every_tab_and_marks_its_own(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        windows = json.loads(proxy.safari(op="list")["content"][0]["text"])
        self.assertEqual([(tab["tab_index"], tab.get("yours", False)) for tab in windows[0]["tabs"]],
                         [(1, False), (2, False), (3, True)])
        self.assertNotIn("mark", windows[0]["tabs"][2])  # the mark is ucu's business

    def test_reads_the_users_tabs_but_changes_them_only_when_told(self):
        proxy = WatchingProxy(self)
        self.assertFalse(proxy.safari(op="read", window_id=51, tab_index=1)["isError"])
        refused = proxy.safari(op="click", window_id=51, tab_index=1, selector="a")
        self.assertIn("the user's", refused["content"][0]["text"])
        self.assertFalse(proxy.safari(op="click", window_id=51, tab_index=1, selector="a", allow_user_tab=True)["isError"])
        viewing = proxy.safari(op="click", window_id=51, tab_index=2, selector="a", allow_user_tab=True)
        self.assertIn("is viewing", viewing["content"][0]["text"])
        self.assertFalse(proxy.safari(op="click", window_id=51, tab_index=2, selector="a", allow_user_tab=True,
                                      allow_current_tab=True)["isError"])
        self.assertEqual(len(proxy.safari_calls("click")), 2)

    def test_takes_a_screenshot_of_a_copy_while_its_tab_is_behind_the_users(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        image, note = proxy.safari(op="shot")["content"]
        self.assertEqual((image["type"], image["mimeType"], base64.b64decode(image["data"])),
                         ("image", "image/jpeg", b"picture"))
        self.assertIn("fresh copy", note["text"])
        self.assertEqual(proxy.safari_calls("show_window")[0]["bounds"]["x"], -1900)  # on the agent's desktop
        copy = proxy.safari_calls("navigate")[0]
        self.assertEqual((copy["window_id"], copy["tab_index"], copy["url"]), (900, 1, "https://a.test"))
        self.assertEqual([call["window_id"] for call in proxy.safari_calls("close_window")], [900])  # and gone again
        proxy.end_turn()
        time.sleep(0.5)
        self.assertEqual(proxy.safari_calls("hide_window"), [])  # nothing of its own is left to hide

    def test_takes_a_screenshot_of_the_users_window_while_it_shows_its_tab(self):
        proxy = WatchingProxy(self)
        (Path(proxy.home.name) / "tab-in-front").touch()
        proxy.safari(op="open", url="https://a.test")
        self.assertEqual([item["type"] for item in proxy.safari(op="shot")["content"]], ["image"])
        self.assertEqual(proxy.safari_calls("create_window"), [])
        self.assertIn("-l51", proxy.screencapture_args())

    def test_captures_only_its_own_window(self):
        proxy = WatchingProxy(self)
        self.assertTrue(proxy.safari(op="shot", window_id=51, tab_index=2)["isError"])

    def test_closes_its_tabs_when_the_chat_ends(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.process.stdin.close()
        proxy.process.wait(10)
        self.assertEqual(proxy.safari_calls("close_tab")[0]["own"]["mark"], proxy.safari_calls("open_tab")[0]["mark"])
        self.assertEqual(proxy.safari_calls("close_window"), [])

    def test_takes_its_tab_away_to_the_agents_desktop_and_back_after_the_turn(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        away = proxy.safari(op="away")["content"][0]["text"]
        self.assertIn("private desktop", away)
        self.assertEqual(proxy.safari_calls("show_window")[0]["bounds"]["x"], -1900)  # in sight there, so awake
        there = proxy.safari_calls("navigate")[0]
        self.assertEqual((there["window_id"], there["tab_index"], there["url"]), (900, 1, "https://a.test"))
        self.assertEqual(len(proxy.safari_calls("close_tab")), 1)  # it left the user's window
        proxy.safari(op="click", selector="a")
        step = proxy.safari_calls("click")[0]
        self.assertEqual((step["window_id"], step["tab_index"], step["away"], "own" in step), (900, 1, True, False))
        self.assertEqual([item["type"] for item in proxy.safari(op="shot")["content"]], ["image"])  # as it is
        self.assertEqual(len(proxy.safari_calls("create_window")), 1)
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.safari_calls("close_window"))
        back = proxy.safari_calls("open_tab")[-1]
        self.assertEqual((back["url"], back["mark"]), ("https://a.test", proxy.safari_calls("open_tab")[0]["mark"]))
        proxy.safari(op="click", selector="a")
        self.assertIn("own", proxy.safari_calls("click")[-1])  # a tab of the user's window again

    def test_closes_a_page_that_is_away_with_the_chat(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        self.assertTrue(proxy.safari(op="away", window_id=51, tab_index=1)["isError"])  # the user's stay put
        proxy.process.stdin.close()
        proxy.process.wait(10)
        self.assertEqual([call["window_id"] for call in proxy.safari_calls("close_window")], [900])

    def test_has_the_helper_undo_the_focus_a_step_in_safari_takes(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="list")
        proxy.look("Safari")
        proxy.act({"do": "click", "on": 1}, app="Safari")
        self.assertEqual([command["ours"] for command in proxy.commands("ours")], ["Safari"])

    def test_brings_its_tab_to_the_front_when_the_user_asks(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        self.assertIn("in front of the user", proxy.safari(op="show")["content"][0]["text"])
        self.assertEqual(proxy.safari_calls("show_tab")[0]["own"]["tab_index"], 3)
        self.assertIn("Safari", [command["allow"] for command in proxy.commands("allow")])
        self.assertIn("nothing to take back", proxy.safari(op="hide")["content"][0]["text"])
        self.assertTrue(proxy.safari(op="show", window_id=51, tab_index=1)["isError"])  # the user's stay put

    def test_says_how_to_turn_on_what_safari_needs(self):
        proxy = WatchingProxy(self)
        result = proxy.safari(op="open", url="https://no-javascript.test")
        self.assertTrue(result["isError"])
        self.assertIn("Safari > Develop > Allow JavaScript from Apple Events", result["content"][0]["text"])

    def test_points_to_the_tool_when_the_user_is_in_safari(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        self.assertIn("`safari` tool", proxy.notes(proxy.look("Safari"))[0])


    def test_puts_files_in_a_page_without_its_picker(self):
        proxy = WatchingProxy(self)
        report = Path(proxy.home.name) / "My Report.pdf"
        report.write_bytes(b"%PDF-1.4")
        proxy.safari(op="open", url="https://a.test")
        result = proxy.safari(op="upload", selector="#file", paths=[str(report)])
        self.assertEqual(json.loads(result["content"][0]["text"])["uploaded"], ["My Report.pdf"])
        call = proxy.safari_calls("upload")[0]
        self.assertEqual(call["files"], [{"path": str(report), "name": "My Report.pdf", "type": "application/pdf"}])
        self.assertEqual((call["own"]["window_id"], call["own"]["tab_index"], call["selector"]), (51, 3, "#file"))
        self.assertNotIn("paths", call)

    def test_uploads_only_files_it_can_find(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        for paths in (["notes.txt"], [str(Path(proxy.home.name) / "missing.txt")], [proxy.home.name], []):
            result = proxy.safari(op="upload", paths=paths)
            self.assertTrue(result["isError"], paths)
        self.assertEqual(proxy.safari_calls("upload"), [])

    def test_uploads_to_a_tab_of_the_users_only_when_told(self):
        proxy = WatchingProxy(self)
        report = Path(proxy.home.name) / "report.csv"
        report.write_text("a,b")
        refused = proxy.safari(op="upload", window_id=51, tab_index=1, paths=[str(report)])
        self.assertIn("the user's", refused["content"][0]["text"])
        self.assertEqual(proxy.safari_calls("upload"), [])


class ChromeTest(unittest.TestCase):
    def test_works_in_a_window_of_its_own_on_the_agents_desktop(self):
        proxy = WatchingProxy(self)
        opened = json.loads(proxy.chrome(op="open", url="https://a.test")["content"][0]["text"])
        proxy.chrome(op="read", what="text")
        self.assertEqual(opened["window_id"], 901)
        made = proxy.chrome_calls("create_window")[0]
        self.assertEqual(made["bounds"], {"x": -1900, "y": -1160, "width": 1280, "height": 900})
        self.assertEqual(proxy.chrome_calls("read")[0]["window_id"], 901)
        self.assertIn("google chrome", [name for command in proxy.commands("watch") for name in command["watch"]])
        self.assertEqual(proxy.safari_calls(), [])

    def test_hides_its_window_after_the_turn_and_brings_it_back_for_the_next(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        self.assertEqual(proxy.chrome_calls("show_window"), [])
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.chrome_calls("hide_window"))
        proxy.chrome(op="read")
        self.assertEqual(proxy.chrome_calls("show_window")[0]["bounds"]["x"], -1900)

    def test_closes_its_window_when_the_chat_ends(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.process.stdin.close()
        proxy.process.wait(10)
        self.assertEqual(proxy.chrome_calls("close_window")[0]["window_id"], 901)

    def test_captures_its_own_window_where_it_put_it(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        image = proxy.chrome(op="shot")["content"][0]
        self.assertEqual(base64.b64decode(image["data"]), b"picture")
        self.assertIn("-l6", proxy.screencapture_args())

    def test_picks_its_own_window_when_the_user_has_the_same_page_open(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://mail.test")
        proxy.look("Google Chrome", window="Mail")
        snapshot = proxy.engine_calls("snapshot")[0]
        self.assertEqual(snapshot[snapshot.index("--window-id") + 1], "w-6")

    def test_says_how_to_turn_on_what_chrome_needs(self):
        proxy = WatchingProxy(self)
        result = proxy.chrome(op="open", url="https://no-javascript.test")
        self.assertTrue(result["isError"])
        self.assertIn("ask them to turn on View > Developer > Allow JavaScript from Apple Events, in Chrome",
                      result["content"][0]["text"])

    def test_points_to_the_tool_when_the_user_is_in_chrome(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        self.assertIn("`chrome` tool", proxy.notes(proxy.look("Google Chrome"))[0])
        self.assertEqual(proxy.notes(proxy.look("Google Chrome", window="Mail")), [])

    def test_keeps_the_users_browser_windows_where_they_are(self):
        proxy = WatchingProxy(self)
        for app in ("Google Chrome", "Safari"):
            result = proxy.call("move_to_desktop", app=app)
            self.assertTrue(result["result"]["isError"])
            self.assertIn("tool", proxy.text(result))
        self.assertEqual(proxy.commands("park"), [])

    def test_stays_out_of_chrome_when_it_is_denied(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Google Chrome"])
        self.assertTrue(proxy.chrome(op="open", url="https://a.test")["isError"])
        self.assertEqual(proxy.chrome_calls(), [])

    def test_has_the_helper_undo_the_focus_its_own_steps_take(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        self.assertEqual([command["ours"] for command in proxy.commands("ours")], ["Google Chrome"])  # its window

    def test_leaves_chrome_to_the_user_while_its_steps_stay_behind(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.chrome(op="open", url="https://b.test")
        proxy.chrome(op="navigate", url="https://c.test")
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.chrome_calls("hide_window"))
        proxy.chrome(op="read")  # its window shows again
        self.assertEqual(len(proxy.commands("ours")), 1)  # only making the window brought Chrome forward

    def test_tells_the_helper_before_a_page_brings_chrome_forward(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        opened = json.loads(proxy.chrome(op="open", url="chrome://no-script/")["content"][0]["text"])
        self.assertEqual((opened["tab_index"], opened["url"]), (2, "chrome://no-script/"))
        proxy.chrome(op="navigate", url="chrome://no-script/again")
        self.assertEqual(len(proxy.commands("ours")), 3)
        typed = [(call["tab_index"], call["url"]) for call in proxy.chrome_calls("navigate") if call.get("typed")]
        self.assertEqual(typed, [(2, "chrome://no-script/"), (2, "chrome://no-script/again")])

    def test_has_the_helper_undo_the_focus_a_step_in_its_page_takes(self):
        proxy = WatchingProxy(self)
        proxy.look("Google Chrome", window="Mail")
        self.assertEqual(proxy.commands("ours"), [])  # no window of its own: the windows are the user's
        proxy.chrome(op="open", url="https://a.test")
        proxy.call("act", app="Google Chrome", window="Mail", steps=[{"do": "click", "on": 1}])
        self.assertEqual(len(proxy.commands("ours")), 2)

    def test_still_tells_the_agent_about_a_window_its_page_opens(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        time.sleep(3.1)  # long after its own window was made
        proxy.chrome(op="navigate", url="chrome://no-script/")  # which brings Chrome forward, as the agent knows
        proxy.report(event="focus", app="Google Chrome", back="Mail")
        proxy.report(event="window", app="Google Chrome", kind="window", title="Sign in", text="", buttons=[],
                     main=False)
        notes = proxy.notes(proxy.look())
        self.assertEqual(len(notes), 1)
        self.assertIn("Sign in", notes[0])

    def test_shows_its_window_to_the_user_and_keeps_working_in_it(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        shown = proxy.chrome(op="show")
        self.assertIn("keep working in it", shown["content"][0]["text"])
        self.assertEqual(proxy.chrome_calls("show_to_user")[0]["window_id"], 901)
        self.assertIn("Google Chrome", [command["allow"] for command in proxy.commands("allow")])
        self.assertFalse(proxy.chrome(op="read")["isError"])
        self.assertEqual(proxy.chrome_calls("read")[-1]["window_id"], 901)
        self.assertEqual(proxy.chrome_calls("show_window"), [])  # it stays where the user has it
        proxy.end_turn()
        time.sleep(0.5)
        proxy.process.stdin.close()
        proxy.process.wait(10)
        self.assertEqual(proxy.chrome_calls("hide_window") + proxy.chrome_calls("close_window"), [])  # theirs to close

    def test_takes_its_window_back_from_the_user(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        self.assertIn("false", proxy.chrome(op="hide")["content"][0]["text"])  # it isn't with them
        proxy.chrome(op="show")
        self.assertIn("true", proxy.chrome(op="hide")["content"][0]["text"])
        self.assertNotIn("only_at", proxy.chrome_calls("hide_window")[0])
        proxy.process.stdin.close()
        proxy.process.wait(10)
        self.assertEqual([call["window_id"] for call in proxy.chrome_calls("close_window")], [901])

    def test_finds_its_tab_again_after_the_user_opened_one_in_its_window(self):
        for browser, calls in (("chrome", "chrome_calls"),):
            proxy = WatchingProxy(self)
            use = getattr(proxy, browser)
            use(op="open", url="https://a.test")
            use(op="show")
            (Path(proxy.home.name) / "user-opened-tab").touch()
            texts = [item["text"] for item in use(op="read")["content"]]
            self.assertEqual(getattr(proxy, calls)("read")[-1]["tab_index"], 2)
            self.assertIn("changed the tabs of your window", texts[-1])
            self.assertIn('1 "T" https://user.test (they are on it); 2 "T" https://a.test (yours)', texts[-1])
            self.assertEqual(len(use(op="read")["content"]), 1)  # told once
            self.assertIn("would switch it", use(op="shot")["content"][0]["text"])  # they are on their tab
            use(op="close")
            self.assertEqual(getattr(proxy, calls)("close_tab")[-1]["tab_index"], 2)  # its own tab, not theirs
            self.assertEqual(getattr(proxy, calls)("clear_window"), [])

    def test_tells_the_agent_when_the_user_closed_its_window(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.chrome(op="show")
        (Path(proxy.home.name) / "user-closed-window").touch()
        closed = proxy.chrome(op="read")
        self.assertTrue(closed["isError"])
        self.assertIn("closed the window", closed["content"][0]["text"])
        self.assertFalse(proxy.chrome(op="open", url="https://b.test")["isError"])
        self.assertEqual(len(proxy.chrome_calls("create_window")), 2)
        proxy.chrome(op="show")
        (Path(proxy.home.name) / "user-closed-window").touch()
        opened = proxy.chrome(op="open", url="https://c.test")  # the step that needs no window says so and goes on
        self.assertIn("closed the window", opened["content"][-1]["text"])
        self.assertEqual(len(proxy.chrome_calls("create_window")), 3)

    def test_shows_only_its_own_tab(self):
        proxy = WatchingProxy(self)
        self.assertTrue(proxy.chrome(op="show", window_id=61, tab_index=1)["isError"])
        self.assertEqual(proxy.chrome_calls("show_to_user"), [])

    def test_leaves_its_window_with_the_user_once_it_left_the_desktop(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        (Path(proxy.home.name) / "window-moved").touch()
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.chrome_calls("hide_window"))
        self.assertEqual(proxy.chrome_calls("hide_window")[0]["only_at"]["x"], -1900)
        proxy.wait_until(lambda: "call `open` first" in proxy.chrome(op="read")["content"][0]["text"])

    def test_follows_its_desktop_when_macos_moves_it(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        (Path(proxy.home.name) / "desktop-moved").touch()  # another chat's desktop left, so this one moved
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.chrome_calls("hide_window"))
        self.assertEqual(proxy.chrome_calls("hide_window")[0]["only_at"]["x"], -3820)  # where its window is now
        self.assertFalse(proxy.chrome(op="read")["isError"])  # so the window is still its own

    def test_does_several_operations_in_one_call(self):
        proxy = WatchingProxy(self)
        result = proxy.chrome(steps=[{"op": "open", "url": "https://a.test"},
                                     {"op": "type", "selector": "#q", "text": "x"},
                                     {"op": "read", "what": "interactive"}])
        said = result["content"][0]["text"].splitlines()
        self.assertFalse(result["isError"])
        self.assertEqual([line.split(":")[0] for line in said], ["1 open", "2 type", "3 read"])
        self.assertIn('c1 a \\"Docs\\" -> /docs\\nc2 input[file]', said[2])
        self.assertEqual([call["op"] for call in proxy.chrome_calls()][-3:], ["open_tab", "type", "read"])

    def test_stops_at_the_operation_that_fails_and_says_what_ran(self):
        proxy = WatchingProxy(self)
        result = proxy.chrome(steps=[{"op": "open", "url": "https://a.test"},
                                     {"op": "click", "window_id": 61, "tab_index": 1, "selector": "a"},
                                     {"op": "read"}])
        said = result["content"][0]["text"]
        self.assertTrue(result["isError"])
        self.assertIn("1 open: ", said)
        self.assertIn("Step 2 failed: That tab is the user's", said)
        self.assertEqual(proxy.chrome_calls("read"), [])

    def test_doesnt_tell_the_agent_about_the_window_it_just_made(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.report(event="focus", app="Google Chrome", back="Mail")
        proxy.report(event="window", app="Google Chrome", kind="window", title="New Tab", text="", buttons=[],
                     main=False)
        self.assertEqual(proxy.notes(proxy.look()), [])


class CompanionProxy(WatchingProxy):
    """A server next to a stand-in for ucu's Chrome extension and its host, answering on their socket. Window 902 is
    the one the extension makes, in the Chrome that the fake osascript answers for. It can't do what `refuses` names."""

    def __init__(self, test, refuses=()):
        usual, tempfile.tempdir = tempfile.tempdir, "/tmp"  # a socket's path has to be short
        try:
            super().__init__(test)
        finally:
            tempfile.tempdir = usual
        self.asked, self.refuses = [], refuses
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(Path(self.home.name) / "Library/Application Support/ucu/chrome.sock"))
        self.listener.listen()
        test.addCleanup(self.listener.close)
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                link, _ = self.listener.accept()
            except OSError:
                return
            with link:
                request = json.loads(link.makefile().readline())
                self.asked.append(request)
                reply = {"ok": True, "result": {"went": True}}
                if request["op"] in self.refuses:
                    reply = {"ok": False, "error": "Invalid value for bounds."}
                elif request["op"] == "create_window":
                    state = Path(self.home.name) / "safari.json"
                    browsers = json.loads(state.read_text())
                    browsers["chrome"]["windows"].append({"window_id": 902, "visible": True, "current_tab_index": 1,
                                                          "tabs": []})
                    state.write_text(json.dumps(browsers))
                    reply = {"ok": True, "result": {"window_id": 902}}
                link.sendall((json.dumps(reply) + "\n").encode())


class CompanionTest(unittest.TestCase):
    def test_makes_its_chrome_window_through_the_extension_when_it_answers(self):
        proxy = CompanionProxy(self)
        opened = json.loads(proxy.chrome(op="open", url="https://a.test")["content"][0]["text"])
        proxy.chrome(op="open", url="https://b.test")
        self.assertEqual(opened["window_id"], 902)
        self.assertEqual(proxy.asked, [{"op": "create_window",
                                        "bounds": {"x": -1900, "y": -1160, "width": 1280, "height": 900}}])
        self.assertEqual(proxy.chrome_calls("create_window"), [])
        self.assertEqual(proxy.commands("ours"), [])  # nothing brought Chrome forward

    def test_has_the_extension_load_a_page_that_runs_no_script(self):
        proxy = CompanionProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        opened = json.loads(proxy.chrome(op="open", url="chrome://no-script/")["content"][0]["text"])
        self.assertEqual(opened["url"], "chrome://no-script/")
        self.assertEqual(proxy.asked[1], {"op": "navigate", "window_id": 902, "tab_index": 2,
                                          "url": "chrome://no-script/"})
        self.assertEqual([(call.get("sent"), call.get("typed")) for call in proxy.chrome_calls("navigate")],
                         [(True, None)])
        self.assertEqual(proxy.commands("ours"), [])

    def test_goes_through_applescript_when_the_extension_cannot(self):
        proxy = CompanionProxy(self, refuses=("create_window", "navigate"))
        opened = json.loads(proxy.chrome(op="open", url="https://a.test")["content"][0]["text"])
        proxy.chrome(op="navigate", url="chrome://no-script/")
        self.assertEqual(opened["window_id"], 901)
        self.assertEqual([request["op"] for request in proxy.asked], ["create_window", "navigate"])
        self.assertEqual(len(proxy.chrome_calls("create_window")), 1)
        self.assertTrue(proxy.chrome_calls("navigate")[-1]["typed"])
        self.assertEqual(len(proxy.commands("ours")), 2)  # as without the extension

    def test_leaves_safari_to_applescript(self):
        proxy = CompanionProxy(self)
        proxy.safari(op="open", url="https://a.test")
        self.assertEqual(proxy.asked, [])
        self.assertEqual(len(proxy.safari_calls("open_tab")), 1)

    def test_its_host_relays_between_the_chats_and_the_extension(self):
        home = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(home.cleanup)
        host = subprocess.Popen([sys.executable, "-I", str(ROOT / "scripts/ucu-chrome-host.py")],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, env={**os.environ, "HOME": home.name})
        self.addCleanup(host.kill)
        path = Path(home.name) / "Library/Application Support/ucu/chrome.sock"
        deadline = time.time() + 5
        while not path.exists() and time.time() < deadline:
            time.sleep(0.02)
        with socket.socket(socket.AF_UNIX) as chat:
            chat.connect(str(path))
            chat.sendall(b'{"op": "navigate", "url": "chrome://version"}\n')
            request = json.loads(host.stdout.read(struct.unpack("=I", host.stdout.read(4))[0]))
            self.assertEqual((request["op"], request["url"]), ("navigate", "chrome://version"))
            reply = json.dumps({"id": request["id"], "ok": True, "result": {"went": True}}).encode()
            host.stdin.write(struct.pack("=I", len(reply)) + reply)
            host.stdin.flush()
            self.assertEqual(json.loads(chat.makefile().readline())["result"], {"went": True})
        host.stdin.close()  # Chrome went away
        self.assertEqual(host.wait(5), 0)
        self.assertFalse(path.exists())
        host.stdout.close()


class FocusNoteTest(unittest.TestCase):
    def test_tells_the_agent_when_the_user_got_their_window_back(self):
        proxy = WatchingProxy(self)
        proxy.look()
        proxy.report(event="focus", app="Google Chrome", back="Inbox", window=True)
        note = proxy.notes(proxy.look())[0]
        self.assertIn("Google Chrome gave one of your windows the user's keyboard", note)


class WindowNoteTest(unittest.TestCase):
    def setUp(self):
        self.proxy = load_proxy()

    def test_lists_windows_of_every_app_without_an_app(self):
        self.proxy.WINDOW_HELPER = Path("/bin/echo")
        self.assertEqual(self.proxy.run_window_tool("list_windows", {}), ("list", False))
        self.assertEqual(self.proxy.run_window_tool("list_windows", {"app": "Safari"}), ("list Safari", False))

    def test_quotes_what_a_window_says_on_one_line(self):
        note = self.proxy.window_note({"event": "window", "app": "Safari", "kind": "window", "title": 'A "quoted" title',
                                       "text": "line one\nline two " + "x" * 400, "buttons": []})
        self.assertIn(r'titled "A \"quoted\" title"', note)
        self.assertIn('"line one line two x', note)
        self.assertNotIn("\n", note)
        self.assertLess(len(note), 500)

    def test_says_how_to_reach_each_kind_of_window(self):
        sheet = self.proxy.window_note({"event": "window", "app": "Notes", "kind": "sheet"})
        system = self.proxy.window_note({"event": "window", "app": "SecurityAgent", "kind": "system dialog"})
        main = self.proxy.window_note({"event": "window", "app": "Notes", "kind": "window", "main": True})
        self.assertIn("look shows it", sheet)
        self.assertIn("may need the user", system)
        self.assertIn("main window now", main)


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.proxy = load_proxy()

    def test_skips_containers_with_nothing_to_say(self):
        lines, _refs, _points, labels, _kinds = self.proxy.render({"tree": {"role": "group", "children": [
            {"role": "button", "name": "OK", "ref_id": "@s:e3"}]}})
        self.assertEqual(lines, ["3 button OK"])
        self.assertEqual(labels, {3: ("ok", "3 button OK")})

    def test_leaves_out_what_only_repeats_the_element_it_is_in(self):
        lines = self.proxy.render({"tree": {"role": "webarea", "name": "Page", "children": [
            {"role": "link", "name": "Gmail ", "ref_id": "@s:e8", "available_actions": ["ScrollTo"], "children": [
                {"role": "statictext", "name": "Gmail", "available_actions": ["ScrollTo"]}]},
            {"role": "group", "name": "Total", "children": [{"role": "statictext", "name": "42"}]}]}})[0]
        self.assertEqual(lines, ["webarea Page", "\t8 link Gmail ", "\tgroup Total", "\t\tstatictext 42"])

    def test_keeps_the_lines_a_found_line_is_inside_of(self):
        lines = ["window W", "\tgroup A", "\t\t1 button Save", "\tgroup B", "\t\t2 button Open", "\t3 button Save as"]
        self.assertEqual(self.proxy.containing(lines, "save"),
                         ["window W", "\tgroup A", "\t\t1 button Save", "\t3 button Save as"])

    def test_shrinks_the_picture_of_a_window_larger_than_models_read(self):
        self.assertEqual(self.proxy.picture_scale({"width": 230, "height": 408}), 1)
        scale = self.proxy.picture_scale({"width": 1512, "height": 982})
        self.assertLessEqual(1512 * scale * 982 * scale, 1_150_001)
        self.assertAlmostEqual(self.proxy.picture_scale({"width": 3000, "height": 300}), 1568 / 3000)

    def test_writes_a_pages_elements_as_short_lines(self):
        lines = self.proxy.interactive_lines([
            {"ref": "c1", "tag": "a", "text": "Docs", "href": "https://a.test/docs"},
            {"ref": "c2", "tag": "input", "type": "file", "text": ""}], "https://a.test/start")
        self.assertEqual(lines, 'c1 a "Docs" -> /docs\nc2 input[file] ""')

    def test_diffs_keep_numbers_current(self):
        said = self.proxy.changes("Calc", ["1 a", "2 b", "3 c"], ["1 a", "2 b", "3 d"])
        self.assertIn("+ 3 d", said)
        self.assertIn("- 3 c", said)

    def test_shows_the_whole_window_when_most_of_it_changed(self):
        self.assertIsNone(self.proxy.changes("Calc", ["1 a", "2 b"], ["1 x", "2 y"]))


if __name__ == "__main__":
    unittest.main()
