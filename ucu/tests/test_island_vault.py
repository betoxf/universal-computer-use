"""Tests for the Notch Island approvals, Passkey Touch ID indicator, and blind secret vault."""
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_windows import WatchingProxy  # noqa: E402


def host_matches(host, allowed):
    h, a = host.lower().strip("."), allowed.lower().strip(".")
    return h == a or h.endswith("." + a)


class FakeIslandProxy(WatchingProxy):
    """A WatchingProxy wired to an in-process fake `ucu-island` Unix socket server."""

    def __init__(self, test):
        usual, tempfile.tempdir = tempfile.tempdir, "/tmp"  # Unix socket path length limit
        try:
            super().__init__(test)
        finally:
            tempfile.tempdir = usual
        self.island_requests = []
        self.vault_entries = {}
        self.remembered_keys = set()
        self.auth_prefs = {}
        self.accounts = {}
        self.next_approve = {"decision": "approved", "remembered": False}
        self.next_request = {"decision": "filled", "username": "beto@test.io",
                             "secret": "typed-in-notch-pass-99", "remember": True}
        self.passkey_events = []

        sock_path = Path(self.home.name) / "Library/Application Support/ucu/island.sock"
        sock_path.parent.mkdir(parents=True, exist_ok=True)
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(sock_path))
        self.listener.listen()
        test.addCleanup(self.listener.close)
        threading.Thread(target=self._serve, daemon=True).start()

    def vault(self, **arguments):
        return self.request("tools/call", {"name": "vault", "arguments": arguments})

    def ask_user(self, **arguments):
        return self.request("tools/call", {"name": "ask_user", "arguments": arguments})

    def seed_vault(self, entry_id, *, kind="login", label=None, domains=(), app=None,
                   username=None, secret="pw-secret-12345", auto_approve=True, allowed_destinations=()):
        self.vault_entries[entry_id] = {
            "id": entry_id,
            "kind": kind,
            "label": label or entry_id,
            "domains": list(domains),
            "app": app,
            "username": username,
            "secret": secret,
            "auto_approve": auto_approve,
            "allowed_destinations": list(allowed_destinations),
            "ephemeral": False,
        }

    def _meta(self, entry):
        secret = entry["secret"]
        preview = "••••••••" if entry["kind"] == "login" or len(secret) <= 8 else f"{secret[:4]}…{secret[-4:]}"
        return {k: v for k, v in {
            "id": entry["id"], "kind": entry["kind"], "label": entry["label"],
            "domains": entry["domains"], "app": entry.get("app"), "username": entry.get("username"),
            "preview": preview, "auto_approve": entry["auto_approve"], "ephemeral": entry["ephemeral"],
        }.items() if v is not None}

    def _handle(self, req):
        self.island_requests.append(req)
        op = req.get("op")
        if op == "ping":
            return {"ok": True, "version": "fake-island 1", "biometrics": True, "has_secrets": bool(self.vault_entries)}
        if op == "passkey":
            self.passkey_events.append(req)
            return {"ok": True, "active": bool(req.get("active", True))}
        if op == "toast":
            return {"ok": True}
        if op == "agent_state":
            return {"ok": True}
        if op == "auth_plan":
            domain = (req.get("domain") or "").lower()
            oauth = req.get("oauth") or []
            has_pk = bool(req.get("passkey"))
            acct = (req.get("account") or "").lower()
            pref = self.auth_prefs.get(domain)
            if pref:
                if pref["method"] == "oauth" and any(p.lower() == (pref.get("provider") or "").lower() for p in oauth):
                    return {"ok": True, "action": "oauth", "provider": pref["provider"], "auto": True,
                            "source": "site_pref", **({"account": acct or pref.get("account")} if (acct or pref.get("account")) else {})}
                if pref["method"] == "passkey" and has_pk:
                    return {"ok": True, "action": "passkey", "auto": True, "source": "site_pref"}
            for prov in oauth:
                if f"oauth:{prov.lower()}" in self.remembered_keys:
                    return {"ok": True, "action": "oauth", "provider": prov, "auto": True, "source": "global_oauth"}
            return {"ok": True, "action": "ask"}
        if op == "set_auth_pref":
            self.auth_prefs[(req.get("domain") or "").lower()] = {
                "method": req.get("method"), "provider": req.get("provider"), "account": req.get("account")}
            return {"ok": True}
        if op == "account_list":
            return {"ok": True, "accounts": list(self.accounts.values())}
        if op == "account_save":
            email = req["email"]
            self.accounts[email] = {"id": email, "email": email, "provider": req.get("provider", "google"),
                                    "domains": req.get("domains", []), "is_default": req.get("is_default", False)}
            return {"ok": True, "account": self.accounts[email]}
        if op == "approve":
            gk = req.get("global_key")
            rk = req.get("remember_key")
            if gk and gk in self.remembered_keys:
                return {"ok": True, "decision": "approved", "remembered": True, "scope": "everywhere"}
            if rk and rk in self.remembered_keys:
                return {"ok": True, "decision": "approved", "remembered": True, "scope": "site"}
            reply = {"ok": True, **self.next_approve}
            if reply.get("decision") == "approved" and reply.get("remembered"):
                if reply.get("scope") == "everywhere" and gk:
                    self.remembered_keys.add(gk)
                elif rk:
                    self.remembered_keys.add(rk)
            return reply
        if op == "vault_list":
            domain = req.get("domain")
            kind = req.get("kind")
            items = []
            for entry in self.vault_entries.values():
                if kind and entry["kind"] != kind:
                    continue
                if domain and not any(host_matches(domain, d) for d in entry["domains"]):
                    continue
                items.append(self._meta(entry))
            return {"ok": True, "items": items, "has_secrets": bool(self.vault_entries)}
        if op == "vault_store":
            eid = req.get("id") or req.get("label", "secret").lower().replace(" ", "-")
            entry = {
                "id": eid,
                "kind": req.get("kind", "api_key"),
                "label": req.get("label", eid),
                "domains": list(req.get("domains") or []),
                "app": req.get("app"),
                "username": req.get("username"),
                "secret": req["secret"],
                "auto_approve": req.get("auto_approve", True),
                "allowed_destinations": [],
                "ephemeral": not req.get("remember", False),
            }
            self.vault_entries[eid] = entry
            return {"ok": True, "entry": self._meta(entry), "has_secrets": True}
        if op == "vault_request":
            ans = self.next_request
            if ans["decision"] == "choose_auth":
                if ans.get("remember", True) and req.get("domain"):
                    self.auth_prefs[req["domain"].lower()] = {
                        "method": ans["method"], "provider": ans.get("provider"), "account": req.get("account")}
                return {"ok": True, "decision": "choose_auth", "method": ans["method"],
                        "provider": ans.get("provider"), "remembered": ans.get("remember", True)}
            if ans["decision"] != "filled":
                return {"ok": True, "decision": ans["decision"]}
            eid = req.get("id") or (req.get("domain") or req.get("label") or "item").replace(".", "-")
            entry = {
                "id": eid,
                "kind": req.get("kind", "login"),
                "label": req.get("label", eid),
                "domains": [req["domain"]] if req.get("domain") else [],
                "app": req.get("app"),
                "username": ans.get("username"),
                "secret": ans["secret"],
                "auto_approve": True,
                "allowed_destinations": [],
                "ephemeral": not ans.get("remember", True),
            }
            self.vault_entries[eid] = entry
            return {"ok": True, "decision": "filled", "entry": self._meta(entry),
                    "remembered": not entry["ephemeral"], "username": ans.get("username", ""),
                    "secret": ans["secret"], "has_secrets": True}
        if op == "vault_resolve":
            eid, domain, app, file_path = req.get("id"), req.get("target_domain"), req.get("target_app"), req.get("target_file")
            kind, acct = req.get("kind"), (req.get("account") or "").lower()
            if eid:
                entry = self.vault_entries.get(eid)
            else:
                cands = [e for e in self.vault_entries.values()
                         if (not kind or e["kind"] == kind)
                         and ((domain and any(host_matches(domain, d) for d in e["domains"]))
                              or (app and (e.get("app") or "").lower() == app.lower()))]
                if acct:
                    entry = next((e for e in cands if acct in (e.get("username") or "").lower()), cands[0] if cands else None)
                else:
                    entry = cands[0] if cands else None
            if not entry:
                ctx = (req.get("context_domain") or "").lower()
                if (not kind or kind == "login") and domain and self.accounts:
                    pick = next((a for a in self.accounts.values() if ctx and ctx in a.get("domains", [])), None) \
                        or next((a for a in self.accounts.values() if a.get("is_default")), next(iter(self.accounts.values())))
                    return {"ok": True, "found": True, "decision": "approved", "kind": "account",
                            "username": pick["email"], "secret": "", "entry": {"id": pick["id"], "kind": "account"}}
                return {"ok": True, "found": False}
            if entry["kind"] == "login" and domain and not any(host_matches(domain, d) for d in entry["domains"]):
                return {"ok": False, "error": f"Domain mismatch: login {entry['id']} belongs to {entry['domains']}, not {domain}."}
            dest_key = f"domain:{domain}" if domain else (f"file:{file_path}" if file_path else f"app:{app}")
            already = bool(file_path) or (domain and any(host_matches(domain, d) for d in entry["domains"])) \
                or (app and (entry.get("app") or "").lower() == app.lower()) \
                or dest_key in entry["allowed_destinations"]
            if not (entry["auto_approve"] and already):
                ans = self.next_approve
                if ans["decision"] != "approved":
                    return {"ok": True, "found": True, "decision": ans["decision"], "entry": self._meta(entry)}
                if ans.get("remembered"):
                    entry["allowed_destinations"].append(dest_key)
            return {"ok": True, "found": True, "decision": "approved", "entry": self._meta(entry),
                    "username": entry.get("username", ""), "secret": entry["secret"]}
        if op == "vault_delete":
            if self.next_approve["decision"] != "approved":
                return {"ok": True, "deleted": False, "decision": "denied"}
            return {"ok": True, "deleted": self.vault_entries.pop(req["id"], None) is not None, "decision": "approved"}
        if op == "redact":
            text = req.get("text", "")
            for eid, entry in sorted(self.vault_entries.items(), key=lambda kv: -len(kv[1]["secret"])):
                if len(entry["secret"]) >= 8 and entry["secret"] in text:
                    text = text.replace(entry["secret"], f"[REDACTED:vault:{eid}]")
            return {"ok": True, "text": text, "has_secrets": bool(self.vault_entries)}
        return {"ok": False, "error": f"unknown op {op}"}

    def _serve(self):
        while True:
            try:
                link, _ = self.listener.accept()
            except OSError:
                return
            with link:
                line = link.makefile().readline()
                if not line:
                    continue
                reply = self._handle(json.loads(line))
                link.sendall((json.dumps(reply) + "\n").encode())


class IslandApprovalAndPasskeyTest(unittest.TestCase):
    def test_asks_user_at_notch_and_remembers_session_approval(self):
        proxy = FakeIslandProxy(self)
        proxy.next_approve = {"decision": "approved", "remembered": True, "scope": "everywhere"}
        first = json.loads(proxy.text(proxy.call(
            "ask_user", title='Click "Continue with Google"', domain="vercel.com")))
        self.assertEqual(first, {"decision": "approved", "remembered": True, "scope": "everywhere"})
        approve_req = [r for r in proxy.island_requests if r["op"] == "approve"][0]
        self.assertEqual(approve_req["harness"], "test client")
        self.assertEqual(approve_req["harness_id"], "generic")
        self.assertEqual(approve_req["agent"], "My-Project")
        self.assertEqual(approve_req["global_key"], "oauth:google")
        self.assertEqual(approve_req["remember_key"], "oauth:google:vercel.com")
        # Once "Always allow everywhere" is checked, Continue with Google on ANY site auto-approves!
        proxy.next_approve = {"decision": "denied", "remembered": False}
        other_site = json.loads(proxy.text(proxy.call(
            "ask_user", title='Click "Continue with Google"', domain="stripe.com")))
        self.assertEqual(other_site["decision"], "approved")
        self.assertEqual(other_site["scope"], "everywhere")

    def test_clicking_show_in_notch_brings_browser_tab_forward(self):
        proxy = FakeIslandProxy(self)
        proxy.safari(op="open", url="https://vercel.com/login")
        proxy.next_approve = {"decision": "show", "remembered": False}
        reply = json.loads(proxy.text(proxy.call(
            "ask_user", title='Click "Continue with Google"', browser="safari", domain="vercel.com")))
        self.assertEqual(reply["decision"], "show")
        self.assertTrue(reply["shown"])
        self.assertEqual(len(proxy.safari_calls("show_tab")), 1)

    def test_passkey_auth_prompt_from_window_watcher_drives_touch_id_notch(self):
        proxy = FakeIslandProxy(self)
        proxy.look()
        proxy.report(event="auth_prompt", active=True, app="coreautha", title="Sign in with Passkey",
                     text="Use Touch ID to sign in to github.com")
        proxy.wait_until(lambda: any(e.get("active") is True for e in proxy.passkey_events))
        self.assertEqual(proxy.passkey_events[-1]["prompt"], "Please touch the key")
        self.assertIn("Sign in with Passkey", proxy.passkey_events[-1]["detail"])
        notes = proxy.notes(proxy.look())
        self.assertTrue(any("macOS is asking for Touch ID or a password" in n for n in notes), notes)

        proxy.report(event="auth_prompt", active=False)
        proxy.wait_until(lambda: any(e.get("active") is False for e in proxy.passkey_events))

    def test_the_passkey_kind_lights_nothing_by_itself(self):
        proxy = FakeIslandProxy(self)
        refused = proxy.call("ask_user", title="Please touch the key", kind="passkey", domain="github.com")
        self.assertTrue(refused["result"]["isError"])
        self.assertIn("Pass `browser`", proxy.text(refused))
        off = json.loads(proxy.text(proxy.call("ask_user", title="done", kind="passkey", active=False)))
        self.assertIs(off["active"], False)
        self.assertEqual(proxy.passkey_events, [])  # the banner comes with a sheet that is open, and goes with it

    def test_publishes_active_agent_cursor_state_and_clears_when_turn_ends(self):
        proxy = FakeIslandProxy(self)
        proxy.look("Calculator")
        proxy.act({"do": "click", "on": 1})
        proxy.wait_until(lambda: any(r.get("op") == "agent_state" and r.get("cursor_norm") for r in proxy.island_requests))
        states = [r for r in proxy.island_requests if r.get("op") == "agent_state"]
        self.assertTrue(any(s.get("active") is True and s.get("app") == "Calculator" and s.get("window_id") == 1 for s in states), states)
        self.assertTrue(any(s.get("cursor_norm") for s in states), states)
        proxy.end_turn()
        proxy.wait_until(lambda: any(r.get("op") == "agent_state" and r.get("active") is False for r in proxy.island_requests))

    def test_surfaces_oauth_passkey_and_saved_login_hints_on_navigation(self):
        proxy = FakeIslandProxy(self)
        proxy.seed_vault("a-test", kind="login", domains=["a.test"], username="beto@a.test", secret="my-secret-pw")
        res = proxy.safari(op="open", url="https://a.test/sign-in?oauth=1&passkey=1")
        body = json.loads(res["content"][0]["text"])
        note = res["content"][1]["text"]
        self.assertNotIn("password", body)
        self.assertNotIn("oauth", body)
        self.assertNotIn("passkey", body)
        self.assertIn("UCU Vault has a saved login for a.test", note)
        self.assertIn("Sign in with Google", note)
        self.assertIn("sign-in with a passkey", note)
        self.assertIn("A click of yours opens no sheet", note)

    def test_prefers_on_screen_quick_login_over_password_prompt(self):
        proxy = FakeIslandProxy(self)
        opened = proxy.safari(op="open", url="https://social.test/sign-in?quick-login=1")
        note = opened["content"][1]["text"]
        self.assertIn("Continue as Fernanda", note)
        self.assertIn("Try clicking it yourself first", note)
        # Even if the agent still calls vault(op="fill"), UCU refuses to pop a password prompt while quick_login exists!
        res = proxy.vault(op="fill", browser="safari")
        data = json.loads(proxy.text(res))
        self.assertEqual(data["quick_login_options"], ["Continue as Fernanda"])
        self.assertEqual([r for r in proxy.island_requests if r["op"] == "vault_request"], [])
        # With force_prompt=True (if clicking Continue still required a password), it proceeds to the notch form.
        forced = proxy.vault(op="fill", browser="safari", force_prompt=True)
        self.assertFalse(forced["result"]["isError"])
        self.assertEqual(len([r for r in proxy.island_requests if r["op"] == "vault_request"]), 1)


class PasskeyTouchTest(unittest.TestCase):
    """A passkey sign-in in Safari: the sheet opens, and waits for the touch, where the user doesn't see it."""

    def at_sign_in(self, plan=""):
        proxy = FakeIslandProxy(self)
        (Path(proxy.home.name) / "page-in-sight").touch()
        if plan:
            (Path(proxy.home.name) / "touch").write_text(plan)
        proxy.safari(op="open", url="https://a.test/signin?passkey=1")
        return proxy

    @staticmethod
    def lit(proxy):
        return [event.get("prompt") for event in proxy.passkey_events if event.get("active")]

    @staticmethod
    def presses(proxy):
        return [entry["args"] for entry in proxy.batched() if entry["command"] == "mouse-click"]

    def cleared(self, proxy):
        """Whatever happened, the helper is told it is over, which gives the front back, and the notch is clear."""
        self.assertEqual(len(proxy.commands("touchEnd")), 1)
        proxy.wait_until(lambda: proxy.passkey_events and proxy.passkey_events[-1].get("active") is False)

    def test_presses_the_passkey_button_out_of_sight_and_waits_for_the_touch(self):
        proxy = self.at_sign_in()
        allowed = len(proxy.commands("allow"))
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual((said["method"], said["sheet"], said["clicked"]), ("passkey", "closed", "Sign in with Passkey"))
        self.assertIs(said["touched"], True)
        self.assertIn("took it and closed", said["note"])
        self.assertEqual(proxy.safari_calls("show_tab"), [])  # nothing came to the user,
        self.assertEqual(len(proxy.commands("allow")), allowed)  # and nothing was allowed to
        found = proxy.safari_calls("click_auth_option")[-1]  # the page only finds its button, in the chat's window
        self.assertEqual((found["real"], found["away"]), (True, True))
        self.assertEqual(self.presses(proxy), [{"xy": "640,480", "app": "Safari", "window_id": f"w-{found['window_id']}"}])
        self.assertEqual(proxy.commands("touch")[-1]["window"], found["window_id"])
        self.assertEqual(len(proxy.commands("touchWatch")), 1)
        self.cleared(proxy)
        self.assertEqual(self.lit(proxy), ["Sign in to a.test"])  # the notch names the site, once the sheet is there

    def test_lights_the_notch_only_for_a_sheet_that_opened(self):
        proxy = self.at_sign_in("none")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual(said["sheet"], "none")
        self.assertIn("no sheet opened", said["note"])
        self.assertEqual(len(self.presses(proxy)), 1)
        self.cleared(proxy)
        self.assertEqual(self.lit(proxy), [])

    def test_says_at_the_notch_whether_the_finger_is_read(self):
        proxy = self.at_sign_in("typing")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual(said["sheet"], "closed")
        self.cleared(proxy)
        self.assertEqual(self.lit(proxy), ["Pause, then touch", "Sign in to a.test"])

    def test_asks_a_busy_user_to_pause_before_anything_is_pressed(self):
        proxy = self.at_sign_in("waiting")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual(said["sheet"], "closed")
        self.cleared(proxy)
        self.assertEqual(self.lit(proxy), ["Pause, then touch", "Sign in to a.test"])

    def test_presses_again_when_the_user_got_in_before_the_press(self):
        proxy = self.at_sign_in("interrupted")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual(said["sheet"], "closed")
        self.assertEqual((len(proxy.commands("touch")), len(self.presses(proxy))), (2, 2))
        self.cleared(proxy)

    def test_tells_a_sheet_that_closed_untouched_from_one_that_took_the_touch(self):
        proxy = self.at_sign_in("refused")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual((said["sheet"], said["touched"]), ("closed", False))
        self.assertIn("closed without taking a touch", said["note"])
        self.cleared(proxy)

    def test_gives_up_when_nobody_touches(self):
        proxy = self.at_sign_in("timeout")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual(said["sheet"], "timed out")
        self.assertIn("It was cancelled.", said["note"])
        self.cleared(proxy)

    def test_presses_nothing_while_the_user_is_busy(self):
        proxy = self.at_sign_in("busy")
        refused = proxy.vault(op="fill", browser="safari")
        self.assertTrue(refused["result"]["isError"])
        self.assertIn("opens only in a pause of theirs", proxy.text(refused))
        self.assertIn("for 90 seconds", proxy.text(refused))
        self.assertEqual(self.presses(proxy), [])
        self.assertEqual(len(proxy.commands("touchEnd")), 1)
        self.assertEqual(self.lit(proxy), [])

    def test_waits_at_a_sheet_that_is_open_already(self):
        proxy = self.at_sign_in("left")
        said = json.loads(proxy.text(proxy.vault(op="fill", browser="safari")))
        self.assertEqual(said["sheet"], "closed")
        self.assertEqual(self.presses(proxy), [])  # it is there: nothing is pressed again
        self.cleared(proxy)

    def test_the_notch_tool_takes_the_same_way(self):
        proxy = self.at_sign_in()
        said = json.loads(proxy.text(proxy.call("ask_user", title="Sign in", kind="passkey", browser="safari")))
        self.assertEqual((said["method"], said["sheet"], said["host"]), ("passkey", "closed", "a.test"))
        self.assertEqual(proxy.safari_calls("show_tab"), [])
        self.cleared(proxy)


class VaultAutofillAndSecretRelayTest(unittest.TestCase):
    def test_fills_saved_login_autonomously_via_stdin_without_exposing_secret(self):
        proxy = FakeIslandProxy(self)
        proxy.seed_vault("github", kind="login", domains=["a.test"], username="beto@test.io",
                         secret="ultra-secret-password-42")
        proxy.safari(op="open", url="https://a.test/login")
        reply = proxy.call("vault", op="fill", browser="safari")
        text = proxy.text(reply)
        self.assertFalse(reply["result"]["isError"], text)
        self.assertNotIn("ultra-secret-password-42", text)
        data = json.loads(text)
        self.assertEqual(data["filled"], ["username", "password"])
        self.assertEqual(data["host"], "a.test")
        # Secret MUST go over stdin, never process argv!
        osascript_entries = [cmd for cmd in proxy.commands("osascript") if cmd["osascript"]["op"] == "fill_login"]
        self.assertEqual(len(osascript_entries), 1)
        self.assertTrue(osascript_entries[0]["via_stdin"])
        self.assertEqual(osascript_entries[0]["osascript"]["password"], "ultra-secret-password-42")

    def test_blocks_filling_login_on_mismatched_domain(self):
        proxy = FakeIslandProxy(self)
        proxy.seed_vault("github", kind="login", domains=["github.com"], username="beto@test.io", secret="gh-secret-99")
        proxy.chrome(op="open", url="https://evilgithub.com/login")
        reply = proxy.call("vault", op="fill", browser="chrome", id="github")
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("Domain mismatch", proxy.text(reply))
        self.assertEqual(proxy.chrome_calls("fill_login"), [])

    def test_prompts_in_notch_when_login_missing_and_remembers_for_next_time(self):
        proxy = FakeIslandProxy(self)
        proxy.chrome(op="open", url="https://newsite.test/login")
        reply = proxy.call("vault", op="fill", browser="chrome")
        text = proxy.text(reply)
        self.assertFalse(reply["result"]["isError"], text)
        self.assertNotIn("typed-in-notch-pass-99", text)
        data = json.loads(text)
        self.assertTrue(data["remembered"])
        self.assertEqual(data["filled"], ["username", "password"])
        # Second time: fills autonomously without another vault_request!
        before_requests = sum(1 for r in proxy.island_requests if r["op"] == "vault_request")
        second = proxy.call("vault", op="fill", browser="chrome")
        self.assertFalse(second["result"]["isError"])
        after_requests = sum(1 for r in proxy.island_requests if r["op"] == "vault_request")
        self.assertEqual(before_requests, after_requests)

    def test_browser_passwords_autofill_captures_blindly_and_reuses_autonomously(self):
        proxy = FakeIslandProxy(self)
        proxy.safari(op="open", url="https://applefill.test/login")
        proxy.next_request = {"decision": "show"}
        first = proxy.vault(op="fill", browser="safari")
        text = proxy.text(first)
        self.assertFalse(first["result"]["isError"], text)
        # Raw Apple Passwords secret MUST NEVER enter LLM output!
        self.assertNotIn("apple-passwords-touchid-secret", text)
        data = json.loads(text)
        self.assertEqual(data["decision"], "autofilled")
        self.assertTrue(data["remembered"])
        self.assertEqual(data["host"], "applefill.test")
        # Next login fills autonomously in the background without prompting or showing the tab!
        before_shows = len(proxy.safari_calls("show_tab"))
        second = proxy.vault(op="fill", browser="safari")
        self.assertFalse(second["result"]["isError"], proxy.text(second))
        self.assertNotIn("apple-passwords-touchid-secret", proxy.text(second))
        self.assertEqual(len(proxy.safari_calls("show_tab")), before_shows)
        fills = [c for c in proxy.commands("osascript") if c["osascript"]["op"] == "fill_login"]
        self.assertTrue(fills[-1]["via_stdin"])
        self.assertEqual(fills[-1]["osascript"]["username"], "icloud@apple.test")
        self.assertEqual(fills[-1]["osascript"]["password"], "apple-passwords-touchid-secret")

    def test_remembers_google_oauth_or_passkey_per_site_and_picks_requested_account(self):
        proxy = FakeIslandProxy(self)
        # 1) First time on github.test: user picks Google right in the Notch Login Form -> remembers & clicks Google!
        proxy.chrome(op="open", url="https://github.test/login?oauth=1")
        proxy.next_request = {"decision": "choose_auth", "method": "oauth", "provider": "Google", "remember": True}
        first = json.loads(proxy.text(proxy.vault(op="fill", browser="chrome")))
        self.assertEqual((first["method"], first["provider"], first["remembered"]), ("oauth", "Google", True))
        self.assertEqual(first["clicked"], "Continue with Google")

        # 2) Second visit to github.test: auto-clicks Google WITHOUT prompting the user!
        before_req = sum(1 for r in proxy.island_requests if r["op"] == "vault_request")
        second = json.loads(proxy.text(proxy.vault(op="fill", browser="chrome")))
        self.assertEqual((second["method"], second["provider"], second["auto"]), ("oauth", "Google", True))
        self.assertEqual(sum(1 for r in proxy.island_requests if r["op"] == "vault_request"), before_req)

        # 3) Passkey available on a site (e.g. apple.test): the passkey is used at once. In Chrome, where a sheet
        #    out of sight isn't measured, the user gets the window and touches there, and the notch says nothing.
        proxy.chrome(op="open", url="https://apple.test/signin?passkey=1")
        pk = json.loads(proxy.text(proxy.vault(op="fill", browser="chrome")))
        self.assertEqual((pk["method"], pk["auto"], pk["shown"]), ("passkey", True, True))
        self.assertEqual(proxy.asks()[-1], ("Touch ID to sign in to apple.test", "Google Chrome"))
        self.assertEqual([e for e in proxy.passkey_events if e.get("active")], [])

        # 4) Account-aware vault selection: picks work@co.test over personal@me.test when requested!
        proxy.seed_vault("gh-personal", kind="login", domains=["multi.test"], username="personal@me.test", secret="pw-personal-11")
        proxy.seed_vault("gh-work", kind="login", domains=["multi.test"], username="work@co.test", secret="pw-work-22")
        proxy.chrome(op="open", url="https://multi.test/login")
        picked = proxy.vault(op="fill", browser="chrome", account="work@co.test")
        self.assertFalse(picked["result"]["isError"], proxy.text(picked))
        fills = [c for c in proxy.commands("osascript") if c["osascript"]["op"] == "fill_login"]
        self.assertEqual(fills[-1]["osascript"]["username"], "work@co.test")
        self.assertEqual(fills[-1]["osascript"]["password"], "pw-work-22")

    def test_fills_learned_google_email_automatically_on_two_step_oauth_page(self):
        proxy = FakeIslandProxy(self)
        proxy.accounts["personal@gmail.test"] = {
            "id": "personal-gmail", "email": "personal@gmail.test", "provider": "google",
            "domains": ["github.com", "google.com"], "is_default": True,
        }
        proxy.accounts["work@corp.test"] = {
            "id": "work-corp", "email": "work@corp.test", "provider": "google",
            "domains": ["corp.test"], "is_default": False,
        }
        proxy.safari(op="open", url="https://accounts.google.com/v3/signin/identifier?app_domain=https%3A%2F%2Fgithub.com")
        res = proxy.vault(op="fill", browser="safari")
        self.assertFalse(res["result"]["isError"], proxy.text(res))
        data = json.loads(proxy.text(res))
        self.assertEqual(data["filled"], ["username"])
        self.assertTrue(data["submitted"])
        fills = [c for c in proxy.commands("osascript") if c["osascript"]["op"] == "fill_login"]
        self.assertEqual(fills[-1]["osascript"]["username"], "personal@gmail.test")
        self.assertEqual(fills[-1]["osascript"]["password"], "")

    def test_captures_api_key_blindly_via_copy_button_and_pastes_to_browser_app_and_env(self):
        proxy = FakeIslandProxy(self)
        proxy.chrome(op="open", url="https://platform.openai.test/api-keys")
        cap = proxy.call("vault", op="capture", **{"from": "chrome"}, label="OpenAI API key",
                         click_selector="button.copy-key", remember=True)
        cap_text = proxy.text(cap)
        self.assertFalse(cap["result"]["isError"], cap_text)
        # Raw API key MUST NEVER appear in the LLM's tool result!
        self.assertNotIn("sk-proj-supersecret987654", cap_text)
        cap_data = json.loads(cap_text)
        self.assertEqual(cap_data["source"], "clipboard_intercept")
        self.assertEqual(cap_data["entry"]["preview"], "sk-p…7654")
        secret_id = cap_data["entry"]["id"]

        # 1) Paste into another browser site (via stdin!)
        proxy.safari(op="open", url="https://vercel.test/env")
        paste_web = proxy.call("vault", op="paste", id=secret_id, to="safari", selector="#env-val")
        self.assertFalse(paste_web["result"]["isError"], proxy.text(paste_web))
        self.assertNotIn("sk-proj-supersecret987654", proxy.text(paste_web))
        type_entries = [cmd for cmd in proxy.commands("osascript") if cmd["osascript"]["op"] == "type_secret"]
        self.assertTrue(type_entries[-1]["via_stdin"])
        self.assertEqual(type_entries[-1]["osascript"]["secret"], "sk-proj-supersecret987654")

        # 2) Paste into a native Mac app (via ucu-engine --stdin, never argv!)
        proxy.look("SecretApp")
        paste_app = proxy.vault(op="paste", id=secret_id, to="app", app="SecretApp", name="Note")
        self.assertFalse(paste_app["result"]["isError"], proxy.text(paste_app))
        engine_entries = [json.loads(line) for line in proxy.engine_log.read_text().splitlines()]
        stdin_call = [e for e in engine_entries if "--stdin" in e["args"]][-1]
        self.assertEqual(stdin_call["stdin"], "sk-proj-supersecret987654")
        self.assertNotIn("sk-proj-supersecret987654", " ".join(stdin_call["args"]))

        # 3) Paste into a local .env file seamlessly (autonomous even if next_approve=denied, mode 0600)
        proxy.next_approve = {"decision": "denied"}
        env_path = Path(proxy.home.name) / ".env.local"
        env_path.write_text("# keep me\nOTHER=1\n")
        paste_env = proxy.vault(op="paste", id=secret_id, to="env_file",
                                path=str(env_path), key="OPENAI_API_KEY")
        self.assertFalse(paste_env["result"]["isError"], proxy.text(paste_env))
        self.assertNotIn("sk-proj-supersecret987654", proxy.text(paste_env))
        self.assertEqual(env_path.read_text(), "# keep me\nOTHER=1\nOPENAI_API_KEY=sk-proj-supersecret987654\n")
        self.assertEqual(stat.S_IMODE(env_path.stat().st_mode), 0o600)

        # Updating existing key replaces in place without duplicating
        proxy.vault_entries[secret_id]["secret"] = "sk-proj-rotated9999"
        upd = proxy.vault(op="paste", id=secret_id, to="env_file", path=str(env_path), key="OPENAI_API_KEY")
        self.assertEqual(json.loads(proxy.text(upd))["action"], "updated")
        self.assertEqual(env_path.read_text(), "# keep me\nOTHER=1\nOPENAI_API_KEY=sk-proj-rotated9999\n")

    def test_refuses_non_env_or_system_paths_before_prompting(self):
        proxy = FakeIslandProxy(self)
        proxy.seed_vault("k", kind="api_key", secret="sk-test-12345678")
        for bad in ("/tmp/config.py", "/etc/.env", "relative/.env"):
            res = proxy.vault(op="paste", id="k", to="env_file", path=bad, key="API_KEY")
            self.assertTrue(res["result"]["isError"], bad)
        self.assertEqual([r for r in proxy.island_requests if r["op"] == "vault_resolve"], [])

    def test_captures_secret_from_native_app_and_redacts_page_and_window_reads(self):
        proxy = FakeIslandProxy(self)
        cap = proxy.vault(op="capture", **{"from": "app"}, app="SecretApp", name="API Token",
                          label="Native Token")
        text = proxy.text(cap)
        self.assertFalse(cap["result"]["isError"], text)
        self.assertNotIn("tok-native-99887766", text)

        # Now `look` on SecretApp and `safari read` showing that token MUST redact it!
        looked = proxy.text(proxy.look("SecretApp"))
        self.assertNotIn("tok-native-99887766", looked)
        self.assertIn("[REDACTED:vault:native-token]", looked)

        (Path(proxy.home.name) / "page-text").write_text("Your key is tok-native-99887766 here")
        proxy.safari(op="open", url="https://a.test/keys")
        read = proxy.safari(op="read")["content"][0]["text"]
        self.assertNotIn("tok-native-99887766", read)
        self.assertIn("[REDACTED:vault:native-token]", read)

    def test_vault_list_never_leaks_secrets_and_delete_confirms(self):
        proxy = FakeIslandProxy(self)
        proxy.seed_vault("stripe", kind="api_key", domains=["stripe.com"], secret="sk_live_secretvalue999")
        listed = proxy.text(proxy.call("vault", op="list"))
        self.assertNotIn("sk_live_secretvalue999", listed)
        self.assertIn("sk_l…e999", listed)
        proxy.next_approve = {"decision": "denied"}
        denied = json.loads(proxy.text(proxy.call("vault", op="delete", id="stripe")))
        self.assertFalse(denied["deleted"])
        proxy.next_approve = {"decision": "approved"}
        deleted = json.loads(proxy.text(proxy.call("vault", op="delete", id="stripe")))
        self.assertTrue(deleted["deleted"])


if __name__ == "__main__":
    unittest.main()
