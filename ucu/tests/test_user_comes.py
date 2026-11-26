"""What the user gets when they come to a browser a chat works in: the tab they are looking at stays theirs, and a
click on the browser's Dock icon brings them what the chat has of it out of their sight."""
import json
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_windows import WatchingProxy  # noqa: E402


def texts(result):
    return " ".join(item["text"] for item in result["content"] if item["type"] == "text")


class TabInFrontTest(unittest.TestCase):
    """In Safari the chat's tab is in the user's window. `away` loads its page on the agent's desktop."""

    def looking(self, proxy, yes=True):
        flag = Path(proxy.home.name) / "tab-in-front"
        flag.touch() if yes else flag.unlink()

    def test_leaves_a_tab_the_user_is_looking_at_and_goes_on_in_a_copy(self):
        proxy = WatchingProxy(self)
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        away = texts(proxy.safari(op="away"))
        self.assertIn("stays open in their window", away)
        self.assertIn("private desktop", away)
        self.assertEqual(proxy.safari_calls("close_tab"), [])  # nothing closes under them
        windows = json.loads(proxy.safari(op="list")["content"][0]["text"])
        theirs = next(window for window in windows if window["window_id"] == 51)
        self.assertEqual([tab.get("yours", False) for tab in theirs["tabs"]], [False, False, False])  # it is theirs
        proxy.safari(op="click", selector="a")
        step = proxy.safari_calls("click")[0]
        self.assertEqual((step["window_id"], step["away"]), (900, True))  # the chat goes on in the copy
        refused = proxy.safari(op="click", selector="a", window_id=51, tab_index=3)
        self.assertIn("the user's", texts(refused))  # and asks before it touches theirs

    def test_closes_a_tab_the_user_isnt_looking_at_as_before(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        self.assertNotIn("stays open", texts(proxy.safari(op="away")))
        self.assertEqual(len(proxy.safari_calls("close_tab")), 1)

    def test_closes_its_tab_in_a_window_safari_got_for_it(self):
        proxy = WatchingProxy(self)
        (Path(proxy.home.name) / "no-user-window").touch()  # so the window shows the chat's tab, behind what they use
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        self.assertNotIn("stays open", texts(proxy.safari(op="away")))
        self.assertEqual(len(proxy.safari_calls("close_tab")), 1)

    def test_takes_the_tab_that_stayed_open_back_after_the_turn(self):
        proxy = WatchingProxy(self)
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.safari_calls("close_window"))
        self.assertEqual(len(proxy.safari_calls("open_tab")), 1)  # no second tab of the page
        proxy.safari(op="click", selector="a")
        self.assertEqual(proxy.safari_calls("click")[-1]["own"]["mark"], proxy.safari_calls("open_tab")[0]["mark"])

    def test_comes_back_in_a_tab_of_its_own_when_the_user_looks_at_an_older_page(self):
        proxy = WatchingProxy(self)
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.safari(op="navigate", url="https://a.test/next")
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.safari_calls("close_window"))
        self.assertEqual([call["url"] for call in proxy.safari_calls("open_tab")], ["https://a.test", "https://a.test/next"])
        self.assertEqual([call for call in proxy.safari_calls("navigate") if "own" in call], [])  # nothing changes under their eyes

    def test_brings_the_tab_it_left_up_to_date_once_the_user_looks_elsewhere(self):
        proxy = WatchingProxy(self)
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.safari(op="navigate", url="https://a.test/next")
        self.looking(proxy, False)
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.safari_calls("close_window"))
        self.assertEqual([call["url"] for call in proxy.safari_calls("navigate") if "own" in call], ["https://a.test/next"])
        self.assertEqual(len(proxy.safari_calls("open_tab")), 1)

    def test_shows_the_page_in_the_tab_it_left_when_the_agent_shows_it_again(self):
        proxy = WatchingProxy(self)
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.safari(op="navigate", url="https://a.test/next")
        self.assertIn("in front of the user", texts(proxy.safari(op="show")))
        self.assertEqual([call["url"] for call in proxy.safari_calls("navigate") if "own" in call], ["https://a.test/next"])
        self.assertEqual(len(proxy.safari_calls("open_tab")), 1)  # show after show leaves one tab, not a row of them
        self.assertEqual([call["window_id"] for call in proxy.safari_calls("close_window")], [900])

    def test_opens_a_new_tab_when_the_user_went_on_in_the_one_it_left(self):
        proxy = WatchingProxy(self)
        self.looking(proxy)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        (Path(proxy.home.name) / "page-left-site").touch()  # they went to another site in it
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.safari_calls("close_window"))
        self.assertEqual(len(proxy.safari_calls("open_tab")), 2)
        self.assertEqual([call for call in proxy.safari_calls("navigate") if "own" in call], [])  # theirs is left alone


class DockClickTest(unittest.TestCase):
    """ucu-window reports the user's click on the Dock icon of a browser the chat works in, and on the chat's preview
    at the notch."""

    def test_brings_the_window_of_its_page_to_the_user_when_they_click_safari_in_the_dock(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.report(came="dock", app="Safari", front=False, inSight=False)
        proxy.wait_until(lambda: proxy.safari_calls("adopt"))
        mine = proxy.safari_calls("open_tab")[0]
        self.assertEqual((proxy.safari_calls("adopt")[0]["window_id"], proxy.safari_calls("adopt")[0]["mark"]),
                         (900, mine["mark"]))
        self.assertIn("Safari", [command["allow"] for command in proxy.commands("allow")])
        said = proxy.safari(op="read")
        self.assertIn("asked for Safari", texts(said))
        self.assertEqual(proxy.safari_calls("read")[-1]["own"]["mark"], mine["mark"])  # a tab among theirs now
        self.assertNotIn("away", proxy.safari_calls("read")[-1])
        proxy.report(came="dock", app="Safari", front=True, inSight=True)  # it is with them: nothing more comes
        proxy.end_turn()
        time.sleep(0.6)
        self.assertEqual((len(proxy.safari_calls("adopt")), len(proxy.safari_calls("open_tab"))), (1, 1))
        self.assertEqual(proxy.safari_calls("close_window"), [])  # and stays where they have it

    def test_brings_it_at_once_during_a_long_step_of_the_agents(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        (Path(proxy.home.name) / "slow-step").touch()  # the next wait takes three seconds
        waiting = next(proxy.ids)
        proxy.send({"id": waiting, "method": "tools/call",
                    "params": {"name": "safari", "arguments": {"op": "wait", "text": "x"}}})
        proxy.wait_until(lambda: proxy.safari_calls("wait_for"))
        asked = time.monotonic()
        proxy.report(came="dock", app="Safari", front=False, inSight=False)
        proxy.wait_until(lambda: proxy.safari_calls("adopt"))
        self.assertLess(time.monotonic() - asked, 1.5)
        reply = proxy.receive()
        while reply.get("id") != waiting:
            reply = proxy.receive()
        self.assertEqual(proxy.safari_calls("read"), [])
        proxy.safari(op="read")  # and the agent goes on in the tab the user has now
        self.assertIn("own", proxy.safari_calls("read")[-1])

    def test_leaves_a_click_that_brings_the_user_their_own_window_alone(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.report(came="dock", app="Safari", front=False, inSight=True)
        proxy.report(came="dock", app="Safari", front=True, inSight=True)  # nor when they click it again
        time.sleep(0.6)
        self.assertEqual((proxy.safari_calls("adopt"), len(proxy.safari_calls("open_tab"))), ([], 1))
        proxy.end_turn()  # and the page is a tab in their window again when the turn ends, as before
        proxy.wait_until(lambda: len(proxy.safari_calls("open_tab")) == 2)

    def test_brings_back_the_users_own_window_from_the_dock_and_not_the_chats(self):
        for browser, came in (("safari", "adopt"), ("chrome", "show_to_user")):
            with self.subTest(browser=browser):
                proxy = WatchingProxy(self)
                (Path(proxy.home.name) / "users-window-docked").touch()
                proxy.call(browser, op="open", url="https://a.test")
                if browser == "safari":
                    proxy.safari(op="away")
                app = "Safari" if browser == "safari" else "Google Chrome"
                proxy.report(came="dock", app=app, front=False, inSight=False)
                proxy.wait_until(lambda: proxy.browser_calls(browser, "restore_users_window"))
                time.sleep(0.6)
                self.assertEqual(proxy.browser_calls(browser, came), [])
                proxy.report(came="notch", app=app, front=False, inSight=False)  # the notch asks for it
                proxy.wait_until(lambda: proxy.browser_calls(browser, came))
                self.assertEqual(len(proxy.browser_calls(browser, "restore_users_window")), 1)

    def test_brings_its_window_for_a_click_at_the_notch_while_the_user_has_none(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.report(came="notch", app="Safari", front=False, inSight=False)
        proxy.wait_until(lambda: proxy.safari_calls("adopt"))

    def test_joins_the_users_window_as_a_tab_for_a_click_at_the_notch(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.report(came="notch", app="Safari", front=False, inSight=True)
        proxy.wait_until(lambda: proxy.safari_calls("show_tab"))
        mine, theirs = proxy.safari_calls("open_tab")
        self.assertEqual(theirs["url"], "https://a.test")
        self.assertNotEqual(theirs["mark"], mine["mark"])
        self.assertEqual(proxy.safari_calls("show_tab")[0]["own"]["mark"], theirs["mark"])  # in front, in their window
        self.assertEqual(proxy.safari_calls("adopt"), [])  # no second window comes
        said = proxy.safari(op="read")
        self.assertIn("preview at the notch", texts(said))
        self.assertEqual(proxy.safari_calls("read")[-1]["own"]["mark"], theirs["mark"])  # one page from here on
        self.assertEqual(len(proxy.safari_calls("close_window")), 1)  # and the one on the agent's desktop is gone
        proxy.end_turn()
        time.sleep(0.6)
        self.assertEqual(len(proxy.safari_calls("open_tab")), 2)

    def test_shows_its_tab_in_the_users_window_for_a_click_at_the_notch(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.report(came="notch", app="Safari", front=False, inSight=True)
        proxy.wait_until(lambda: proxy.safari_calls("show_tab"))
        self.assertEqual(proxy.safari_calls("show_tab")[0]["own"]["mark"], proxy.safari_calls("open_tab")[0]["mark"])
        self.assertEqual(proxy.safari_calls("adopt"), [])
        self.assertIn("preview at the notch", texts(proxy.safari(op="read")))

    def test_does_nothing_while_the_chats_tab_is_in_the_users_window(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.report(came="dock", app="Safari", front=True, inSight=True)
        time.sleep(0.6)
        self.assertEqual((len(proxy.safari_calls("open_tab")), proxy.safari_calls("show_tab")), (1, []))
        self.assertEqual(proxy.safari_calls("adopt"), [])
        self.assertNotIn("Dock icon", texts(proxy.safari(op="read")))

    def test_answers_a_switch_to_the_browser_as_it_does_a_click_on_its_dock_icon(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.safari(op="away")
        proxy.report(came="switch", app="Safari", front=False, inSight=False)
        proxy.wait_until(lambda: proxy.safari_calls("adopt"))
        self.assertIn("asked for Safari", texts(proxy.safari(op="read")))

    def test_does_nothing_for_a_switch_while_no_page_of_the_chats_is_away(self):
        """The helper tells of every switch that shows the user no window of the browser, also long after a step."""
        proxy = WatchingProxy(self)
        (Path(proxy.home.name) / "users-window-docked").touch()
        proxy.safari(op="open", url="https://a.test")
        proxy.report(came="switch", app="Safari", front=False, inSight=False)
        time.sleep(0.6)
        self.assertEqual((len(proxy.safari_calls("open_tab")), proxy.safari_calls("show_tab")), (1, []))
        self.assertEqual((proxy.safari_calls("adopt"), proxy.safari_calls("restore_users_window")), ([], []))
        said = texts(proxy.safari(op="read"))
        self.assertNotIn("asked for Safari", said)
        self.assertNotIn("preview at the notch", said)

    def test_does_nothing_in_a_browser_the_chat_doesnt_work_in(self):
        proxy = WatchingProxy(self)
        proxy.safari(op="open", url="https://a.test")
        proxy.report(came="dock", app="Google Chrome", front=True, inSight=False)
        time.sleep(0.6)
        self.assertEqual(proxy.chrome_calls(), [])

    def test_brings_its_chrome_window_to_the_user(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.report(came="dock", app="Google Chrome", front=False, inSight=False)
        proxy.wait_until(lambda: proxy.chrome_calls("show_to_user"))
        self.assertEqual(proxy.chrome_calls("show_to_user")[0]["window_id"], 901)
        self.assertIn("Google Chrome", [command["allow"] for command in proxy.commands("allow")])
        said = proxy.chrome(op="read")
        self.assertIn("asked for Google Chrome", texts(said))
        self.assertEqual(proxy.chrome_calls("show_window"), [])  # it stays where the user has it
        proxy.report(came="dock", app="Google Chrome", front=True, inSight=True)  # it is with them already
        time.sleep(0.6)
        self.assertEqual(len(proxy.chrome_calls("show_to_user")), 1)
        proxy.report(came="notch", app="Google Chrome", front=False, inSight=True)  # to the front again
        proxy.wait_until(lambda: proxy.chrome_calls("show_tab"))
        proxy.end_turn()
        time.sleep(0.5)
        self.assertEqual(proxy.chrome_calls("hide_window"), [])  # and theirs to close

    def test_leaves_chrome_to_bring_the_user_their_own_window(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.report(came="dock", app="Google Chrome", front=False, inSight=True)
        time.sleep(0.6)
        self.assertEqual(proxy.chrome_calls("show_to_user"), [])

    def test_keeps_an_empty_chrome_window_to_itself_while_the_user_has_one_of_their_own(self):
        proxy = WatchingProxy(self)
        proxy.chrome(op="open", url="https://a.test")
        proxy.chrome(op="close")
        proxy.report(came="dock", app="Google Chrome", front=True, inSight=True)
        time.sleep(0.6)
        self.assertEqual(proxy.chrome_calls("show_to_user"), [])
        proxy.report(came="dock", app="Google Chrome", front=False, inSight=False)  # with none, they get that one
        proxy.wait_until(lambda: proxy.chrome_calls("show_to_user"))


if __name__ == "__main__":
    unittest.main()
