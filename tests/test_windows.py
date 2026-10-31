"""How ucu-proxy.py keeps apps out of the way, reports new windows and shortens what agents read."""
import copy
import importlib.util
import json
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_proxy import Proxy  # noqa: E402

ENGINE_TOOLS = [{"name": "js", "description": "Control apps.\n\nUse the first matching browser control option from the "
                                              "request:\n\nmany browser examples\n\nIf the user specifies an app, get it."},
                {"name": "js_add_node_module_dir", "description": "Add a directory."},
                {"name": "js_reset", "description": "Reset."},
                {"name": "turn_ended", "description": "Notify."}]
DOCS = """## Computer Use

## API

type AppInfo = { id: string };

type BrowserInfo = { id: string };
interface Browser { readonly browserId: string; }

type State = { apps: AppInfo[]; };

type BrowserOptions = { browser?: string };
interface Tab { readonly id: string; }

declare const cua: {
  getApp(target: string): Promise<App>;

  /** Select without opening a tab. */
  getBrowser(): Promise<Browser>;
  listTabs(): Promise<TabInfo[]>;
};

MCP App tabs support DOM-based interaction.

## Native apps

## Notes

- For browser tabs, `click` holds each press.
- `pressKey()` presses a key.
- Browser `paste` does not restore the clipboard.

"""
POLICY = "# Computer Use Confirmations Policy\n\nThe long policy.\n"


def load_proxy():
    spec = importlib.util.spec_from_file_location("ucu_proxy_under_test", ROOT / "scripts/ucu-proxy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WatchingProxy(Proxy):
    def __init__(self, test):
        super().__init__(test)
        path = Path(self.home.name) / ".local/bin/ucu-window"
        path.parent.mkdir(parents=True)
        path.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{ROOT / "tests/fake_ucu_window.py"}" "$@"\n')
        path.chmod(0o755)
        self.initialize()

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
    def test_opens_a_closed_app_hidden_before_cua_repl_gets_the_call(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Terminal"])
        reply = proxy.call("js", 'let app = await cua.getApp("Closed App");')
        self.assertEqual(proxy.commands("open")[0]["deny"], ["Terminal"])
        self.assertGreater(proxy.events("recv")[-1]["at"], proxy.commands("open")[0]["at"] + 0.15)
        self.assertEqual(len(proxy.notes(reply)), 1)
        self.assertIn("Closed App was closed, so ucu opened it hidden", proxy.notes(reply)[0])

    def test_never_watches_a_denied_app(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Closed Secrets"])
        proxy.call("js", 'let app = await cua.getApp("Closed Secrets");')
        self.assertEqual(proxy.commands("watch"), [])

    def test_drops_a_call_cancelled_while_its_app_opens(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        proxy.send({"id": 99, "method": "tools/call", "params": {
            "name": "js", "arguments": {"code": 'let app = await cua.getApp("Closed App");'}}})
        proxy.send({"method": "notifications/cancelled", "params": {"requestId": 99}})
        proxy.wait_until(lambda: [command for command in proxy.commands("busy") if not command["busy"]])
        self.assertEqual([event for event in proxy.received("tools/call") if event["message"].get("id") == 99], [])

    def test_says_nothing_about_an_app_that_was_already_running(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        self.assertEqual(proxy.notes(proxy.call("js", 'let app = await cua.getApp("Safari");')), [])

    def test_leaves_a_denied_app_closed_and_cua_repl_refuses_it(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=["Closed Secrets"])
        reply = proxy.call("js", 'let app = await cua.getApp("Closed Secrets");')
        self.assertEqual(proxy.notes(reply), [])

    def test_opens_nothing_while_the_policy_cannot_be_read(self):
        proxy = WatchingProxy(self)
        proxy.call("js", 'let app = await cua.getApp("Closed App");')
        self.assertEqual(proxy.commands("open"), [])

    def test_shows_a_hidden_app_before_input_by_coordinates(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        proxy.call("js", 'let app = await cua.getApp("Closed App");')
        proxy.call("js", "await app.click(12);")
        self.assertEqual(proxy.commands("show"), [])
        proxy.call("js", "await app.click([100, 200]);")
        self.assertEqual(proxy.commands("show")[0]["show"], ["Closed App"])
        self.assertGreater(proxy.events("recv")[-1]["at"], proxy.commands("show")[0]["at"])
        proxy.call("js", "await app.click([100, 200]);")
        self.assertEqual(len(proxy.commands("show")), 1)

    def test_shows_a_hidden_app_when_the_engine_finds_no_window_on_screen(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        proxy.call("js", 'let app = await cua.getApp("Closed App");')
        reply = proxy.call("js", "no-windows")  # `app.click(point)`: nothing here says it uses coordinates
        self.assertIn("Closed App was hidden", proxy.notes(reply)[0])
        proxy.wait_until(lambda: proxy.commands("show"))

    def test_leaves_the_app_alone_after_the_agent_showed_it(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        proxy.call("js", 'let app = await cua.getApp("Closed App");')
        proxy.request("tools/call", {"name": "focus_window", "arguments": {
            "app": "Closed App", "title": "x", "activate": True}})
        self.assertEqual(proxy.commands("allow")[0]["allow"], "Closed App")
        proxy.call("js", "await app.click([100, 200]);")
        self.assertEqual(proxy.commands("show"), [])

    def test_shows_a_hidden_app_that_turned_an_action_down(self):
        proxy = WatchingProxy(self)
        proxy.policy(deny=[])
        proxy.call("js", 'let app = await cua.getApp("Closed App");')
        time.sleep(0.3)  # the fake log's start
        notes = proxy.notes(proxy.call("js", "alert:Closed App"))
        self.assertIn("played an alert sound", notes[0])
        self.assertIn("Closed App was hidden", notes[1])

    def test_tells_the_agent_about_a_new_window_once(self):
        proxy = WatchingProxy(self)
        proxy.call("js")
        proxy.report(event="window", app="Safari", kind="dialog", title="Sign in", text="Your password", buttons=["OK"])
        self.assertEqual(proxy.notes(proxy.call("js")), [
            '[ucu: Safari opened a dialog titled "Sign in". Its text: "Your password". Buttons: "OK". '
            "To act on it, call focus_window with its title, then cua.getApp.]"])
        self.assertEqual(proxy.notes(proxy.call("js")), [])

    def test_keeps_a_burst_of_windows_short(self):
        proxy = WatchingProxy(self)
        proxy.call("js")
        for index in range(5):
            proxy.report(event="window", app="Safari", kind="window", title=f"Tab {index}")
        notes = proxy.notes(proxy.call("js"))
        self.assertEqual(len(notes), 4)
        self.assertIn("and 2 more", notes[-1])

    def test_tells_the_agent_when_the_user_got_their_app_back(self):
        proxy = WatchingProxy(self)
        proxy.call("js")
        proxy.report(event="focus", app="Safari", back="Claude")
        self.assertIn("Safari came to the front", proxy.notes(proxy.call("js"))[0])

    def test_marks_the_time_a_call_runs_and_the_apps_it_drives(self):
        proxy = WatchingProxy(self)
        proxy.call("js", 'let app = await cua.getApp("Calculator");')
        proxy.wait_until(lambda: [command for command in proxy.commands("busy") if not command["busy"]])
        self.assertEqual(proxy.commands("watch")[0]["watch"], ["calculator"])
        self.assertEqual([command["busy"] for command in proxy.commands("busy")], [True, False])

    def test_stops_the_helper_when_cua_repl_stops(self):
        proxy = WatchingProxy(self)
        proxy.call("js")
        proxy.wait_until(lambda: proxy.commands("busy"))
        self.assertEqual(proxy.commands("exited"), [])
        proxy.end_turn()
        proxy.wait_until(lambda: proxy.commands("exited"))

    def test_works_with_a_helper_from_before_it_could_watch(self):
        proxy = Proxy(self)
        path = Path(proxy.home.name) / ".local/bin/ucu-window"
        path.parent.mkdir(parents=True)
        path.write_text('#!/bin/sh\necho "usage: ucu-window" >&2\nexit 1\n')
        path.chmod(0o755)
        proxy.policy(deny=[])
        proxy.initialize()
        reply = proxy.call("js", 'let app = await cua.getApp("Closed App");')
        self.assertFalse(any(text.startswith("[ucu:") for text in [item["text"] for item in reply["result"]["content"]]))

    def test_explains_a_refused_app_where_it_happens(self):
        proxy = WatchingProxy(self)
        reply = proxy.call("js", "refuse")
        self.assertIn("deny list", proxy.notes(reply)[0])


class ShorterTest(unittest.TestCase):
    def setUp(self):
        self.proxy = load_proxy()

    def test_lists_windows_of_every_app_without_an_app(self):
        self.proxy.WINDOW_HELPER = Path("/bin/echo")
        self.assertEqual(self.proxy.run_window_tool("list_windows", {}), ("list", False))
        self.assertEqual(self.proxy.run_window_tool("list_windows", {"app": "Safari"}), ("list Safari", False))

    def test_hides_tools_and_browser_examples_from_the_tool_list(self):
        message = {"result": {"tools": copy.deepcopy(ENGINE_TOOLS)}}
        tools = json.loads(self.proxy.Proxy.edit_tools(message))["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["js", "js_reset", "list_windows", "focus_window"])
        self.assertNotIn("many browser examples", tools[0]["description"])
        self.assertIn("cua.getState()", tools[0]["description"])
        self.assertIn("If the user specifies an app", tools[0]["description"])

    def test_adds_the_window_tools_to_the_last_page_only(self):
        message = {"result": {"tools": copy.deepcopy(ENGINE_TOOLS), "nextCursor": "2"}}
        tools = json.loads(self.proxy.Proxy.edit_tools(message))["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["js", "js_reset"])

    def test_leaves_the_browser_part_out_and_returns_it(self):
        shorter, removed = self.proxy.shrink_docs(DOCS + POLICY, keep_browser=False)
        for gone in ("BrowserInfo", "interface Tab", "listTabs", "MCP App tabs", "For browser tabs", "Browser `paste`"):
            self.assertNotIn(gone, shorter)
            self.assertIn(gone, removed)
        for kept in ("type AppInfo", "type State", "declare const cua", "getApp(target", "## Native apps", "pressKey()"):
            self.assertIn(kept, shorter)
        self.assertIn("about browsers", shorter)

    def test_keeps_the_browser_part_for_a_first_call_that_uses_it(self):
        shorter, removed = self.proxy.shrink_docs(DOCS + POLICY, keep_browser=True)
        self.assertEqual((shorter, removed), (DOCS + POLICY, ""))

    def test_summarizes_only_the_policy_the_summary_was_written_from(self):
        self.assertIn("The long policy.", self.proxy.shrink_docs(DOCS + POLICY, keep_browser=True)[0])
        self.proxy.POLICY_SHA256 = self.proxy.hashlib.sha256(POLICY.split("Policy", 1)[1].encode()).hexdigest()
        shorter = self.proxy.shrink_docs(DOCS + POLICY, keep_browser=True)[0]
        self.assertNotIn("The long policy.", shorter)
        self.assertIn(self.proxy.POLICY_SUMMARY, shorter)

    def test_gives_the_browser_part_to_the_first_call_that_needs_it(self):
        proxy = self.proxy.Proxy(None, 1, 1, 1)
        first = {"result": {"content": [{"type": "text", "text": DOCS + POLICY + "x" * 5000}]}}
        proxy.shorten_docs(first, browser=False)
        self.assertNotIn("BrowserInfo", first["result"]["content"][0]["text"])
        later = {"result": {"content": [{"type": "text", "text": "state"}]}}
        self.assertIsNone(proxy.shorten_docs(later, browser=False))
        proxy.shorten_docs(later, browser=True)
        self.assertIn("BrowserInfo", later["result"]["content"][0]["text"])
        last = {"result": {"content": [{"type": "text", "text": "state"}]}}
        self.assertIsNone(proxy.shorten_docs(last, browser=True))

    def test_keeps_the_browser_part_through_a_browsers_own_docs(self):
        proxy = self.proxy.Proxy(None, 1, 1, 1)
        proxy.shorten_docs({"result": {"content": [{"type": "text", "text": DOCS + POLICY + "x" * 5000}]}}, browser=False)
        browser = {"result": {"content": [{"type": "text", "text": "# Other Browser APIs\n" + "y" * 5000}]}}
        proxy.shorten_docs(browser, browser=True)
        self.assertIn("interface Tab", browser["result"]["content"][0]["text"])
        self.assertIn("Other Browser APIs", browser["result"]["content"][1]["text"])

    def test_gives_the_browser_part_to_a_call_that_also_gets_the_docs_again(self):
        proxy = self.proxy.Proxy(None, 1, 1, 1)
        text = DOCS + POLICY + "x" * 5000
        proxy.shorten_docs({"result": {"content": [{"type": "text", "text": text}]}}, browser=False)
        again = {"result": {"content": [{"type": "text", "text": text}]}}
        proxy.shorten_docs(again, browser=True)
        self.assertIn("BrowserInfo", again["result"]["content"][0]["text"])
        self.assertIn("left out", again["result"]["content"][1]["text"])

    def test_shortens_the_sentences_the_engine_repeats(self):
        diff = ('The following is a diff from the previous accessibility tree for Window: "Calculator" with ~ and + '
                "representing changed and added elements, respectively. Removed elements are summarized by ID range.\n"
                "~\t4 text Value: 7")
        content = [{"type": "text", "text": diff}, {"type": "image", "data": "x"},
                   {"type": "text", "text": 'There has been no change in the accessibility tree for Window: "A "B"".\nx'}]
        self.assertTrue(self.proxy.shorten_states(content))
        self.assertEqual(content[0]["text"], 'Diff of "Calculator" (~ changed, + added, removed as ID ranges):\n~\t4 text Value: 7')
        self.assertEqual(content[2]["text"], 'No change in "A "B"".\nx')
        self.assertFalse(self.proxy.shorten_states([{"type": "text", "text": 'Window: "Calculator", App: Calculator.'}]))

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
        self.assertIn("getAXState shows it", sheet)
        self.assertIn("may need the user", system)
        self.assertIn("main window now", main)


if __name__ == "__main__":
    unittest.main()
