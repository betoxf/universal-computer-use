#!/usr/bin/env python3
"""Stdio MCP proxy that Claude Code launches for the `ucu` server.

    ucu-proxy.py [--turn-idle S] [--stop-grace S] [--stop-idle S] [-- <cua-repl command...>]

Without a command it runs cua_repl as the newest usable Codex computer-use plugin
defines it (~/.codex/plugins/cache/openai-bundled/unified-computer-use/<version>/.mcp.json),
read again at every start, so a Codex update reaches open chats the next time
cua_repl starts.

Each chat's Claude Code process starts its own copy, so everything below is per
chat. It passes every message through unchanged, except that it

* adds the Codex turn metadata (`_meta["x-codex-turn-metadata"]` = session_id,
  turn_id) that cua_repl expects on each `tools/call`. Without it the browser
  surface fails with "Missing required Codex turn metadata", and Sky cannot tie
  actions to a turn;
* ends the turn when Claude's turn ends. The Stop hook that `ucu install` adds to
  ~/.claude/settings.json sends SIGINFO to the proxy of the chat whose turn ended
  (`pkill -INFO -P $PPID -f ucu-proxy.py`). Without a hook (an interrupted turn) the turn ends
  after --turn-idle seconds without a call (default 120). Ending a turn runs
  `SkyComputerUseClient turn-ended` (what Codex itself runs after every turn, via
  `notify` in ~/.codex/config.toml) so Sky can drop its per-turn state, and, when
  the turn used the browser surface, calls cua_repl's `turn_ended` tool so
  that surface detaches from its tabs;
* stops cua_repl, with its JavaScript kernel and sandbox processes, once the chat
  has not used it for --stop-grace seconds after a turn ended (default 120), or
  for --stop-idle seconds in any case (default 900). Between uses the chat then
  holds only this proxy (~11 MB) instead of 40-280 MB;
* starts cua_repl again on the chat's next request (~0.3 s), replaying Claude's
  `initialize` handshake. Earlier JavaScript variables such as `app` are gone
  after a restart and must be fetched again;
* leaves out the first-use documentation (~21k characters, ~5.5k tokens) that a
  restarted cua_repl sends again with its first `js` result, when this chat has
  already received an identical copy, and says so in a one-line note. Calling
  `js_reset` brings the documentation back in full on the next `js` call, for
  when the earlier copy is gone from Claude's context (compaction, /clear);
* answers cua_repl's per-app approval prompt (`Allow Computer Use to use "<app>"?`)
  itself from ~/Library/Application Support/ucu/policy.json: apps in `deny` are
  declined and every other app is accepted. The file is read at every prompt, and
  every decision is logged to ~/Library/Logs/ucu/approve.log with the client and
  folder that caused it. If the file cannot be read the prompt goes to the client,
  so a denied app cannot slip through;
* adds two tools of its own next to cua_repl's: `list_windows` and `focus_window`
  pick which window of an app `cua.getApp` acts on (always the app's main window)
  by running ~/.local/bin/ucu-window, which `ucu install` builds from
  native/ucu-window.swift. They answer without starting cua_repl;
* adds ucu's usage rules to the `instructions` in cua_repl's `initialize` reply,
  so they reach every client and not only those with the rules in their own config;
* answers a request left unanswered by a cua_repl that exited on its own with an
  error, instead of leaving Claude waiting for the 5-minute tool timeout. The error
  warns that the action may already have happened, so it is not blindly repeated;
* answers Claude Code's pre-`initialize` `server/discover` probe itself with
  "method not found". cua_repl (rmcp) closes the connection on that probe,
  which makes Claude Code kill and respawn the server (~2 s per session start).

The proxy itself runs for as long as the chat, so Claude never sees ucu
disconnect; only cua_repl stops and starts behind it. (Claude Code 2.1.299 does
reconnect a server that exited, but only on the next call, after its discovery
probe and a full handshake.) SIGINFO is used because its default action is to be
ignored, so a proxy started from an older version of this file, which has no
handler for it, is left alone.

`ucu install` registers this file as the `ucu` server. Its tests are in
tests/test_proxy.py, tests/test_plugin.py and tests/test_policy.py.
"""
import argparse
import hashlib
import itertools
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import unicodedata
import uuid
from pathlib import Path

PLUGIN_DIR = Path.home() / ".codex/plugins/cache/openai-bundled/unified-computer-use"
SKY_CLIENT = (Path.home() / ".codex/computer-use/Codex Computer Use.app/Contents/SharedSupport"
              / "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
META_KEY = "x-codex-turn-metadata"
LOCAL_ERROR = -32603
DOCS_MIN_LENGTH = 4000  # the first-use documentation is ~21k characters; an AX tree never starts with "#"
DOCS_NOTE = ("[ucu restarted and sent its first-use documentation again ({} characters). It is identical "
             "to the copy earlier in this chat, so it was left out. If that copy is no longer in your context, "
             "call js_reset, then js again to get it in full.]\n")
MAY_HAVE_HAPPENED = ("ucu stopped unexpectedly during this call, so its action may already have happened: check "
                     "the app before repeating it. ucu restarts on the next call.")
WAIT_HELPER = Path(__file__).resolve().parent.parent / "js/wait.mjs"
USAGE_RULES = f"""ucu rules:
- `cua.getApp` acts on the app's main window. With several windows or full screen, call `list_windows`, then \
`focus_window` (`unfullscreen: true` if full screen) before `cua.getApp`, and check that the first screenshot shows \
the right window.
- "Computer Use was not approved to use <app>" means the app is on the user's deny list or the user declined: \
don't retry or switch tools; tell the user.
- Remote-desktop and canvas apps can ignore background input. If clicks or keys have no visible effect, stop and tell \
the user.
- Don't sleep a fixed time for a slow app. In the same `js` call, run `const {{ waitForChange }} = await \
import("{WAIT_HELPER}")`, then `await waitForChange(app, () => app.click(8), {{ timeoutMs: 20000 }})`, then take the \
screenshot.
- Pass `timeout_ms` to `js` for slow apps; the default is 30 seconds.
- ucu stops `cua_repl` when idle, so variables such as `app` can disappear: get `app` again at the start of each \
turn. Don't call `js_reset` when you finish.
- Don't let two agents drive the same app at the same time."""


BROWSER_CALL = re.compile(r"\b(getTab|createBrowserTab|getBrowser|getState)\b")
POLICY = Path.home() / "Library/Application Support/ucu/policy.json"
APPROVAL_LOG = Path.home() / "Library/Logs/ucu/approve.log"
APPROVAL_LOG_LIMIT = 1_000_000  # bytes; the log then moves to approve.log.1 and starts again
APPROVAL_PROMPT = re.compile(r'^Allow Computer Use to use "(.+)"\?$')
WINDOW_HELPER = Path.home() / ".local/bin/ucu-window"
APP_PROPERTY = {"type": "string", "description": 'Name or bundle id of a running app, e.g. "Windows App".'}
WINDOW_TOOLS = [
    {"name": "list_windows",
     "description": "List a running macOS app's windows: title, whether it is the main window (the one "
                    "cua.getApp acts on), minimized, full screen, and frame.",
     "inputSchema": {"type": "object", "properties": {"app": APP_PROPERTY}, "required": ["app"]},
     "annotations": {"readOnlyHint": True}},
    {"name": "focus_window",
     "description": "Make one window of a macOS app its main window, so the next cua.getApp(app) acts on it: "
                    "un-minimizes and raises it, optionally leaving full screen first. Fails if the title "
                    "matches no window or several. Get the app again with cua.getApp afterwards and check "
                    "that the first screenshot shows this window.",
     "inputSchema": {"type": "object", "properties": {
         "app": APP_PROPERTY,
         "title": {"type": "string", "description": "Part of the window's title, as list_windows shows it."},
         "unfullscreen": {"type": "boolean", "description": "Leave full screen first (default false)."},
         "activate": {"type": "boolean", "description": "Also bring the app to the front (default false)."}},
         "required": ["app", "title"]}},
]


def notify_sky_turn_ended(payload):
    try:
        subprocess.run([str(SKY_CLIENT), "turn-ended", json.dumps(payload)], cwd=str(Path.home()), timeout=30,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


def app_key(name):
    """An app name for comparing: case and invisible marks (WhatsApp's name starts with one) don't count."""
    return "".join(c for c in str(name) if unicodedata.category(c) != "Cf").strip().casefold()


def policy_decision(params):
    """Return (action, app) for an elicitation. Action is "decline" for an app on the deny list, "accept"
    for any other app, and None when the client should answer: when the policy cannot be read, so that
    a denied app cannot slip through, or when this is not an app approval prompt (app is then None too)."""
    match = APPROVAL_PROMPT.match(str(params.get("message") or ""))
    # An empty answer is only valid while the prompt asks for no fields.
    if not match or params.get("mode") not in (None, "form") or (params.get("requestedSchema") or {}).get("required"):
        return None, None
    app = match.group(1)
    try:
        denied = json.loads(POLICY.read_text())["deny"]
    except (OSError, ValueError, KeyError, TypeError):
        return None, app
    if not isinstance(denied, list):
        return None, app
    meta = params.get("_meta")
    tool = meta.get("tool_params") if isinstance(meta, dict) else None
    bundle_id = tool.get("app") if isinstance(tool, dict) else None
    names = {app_key(name) for name in (app, bundle_id) if name}
    return ("decline" if any(app_key(name) in names for name in denied) else "accept"), app


def run_window_tool(name, arguments):
    """Run ucu-window for a list_windows or focus_window call; return (text, failed)."""
    command = ["list", str(arguments.get("app") or "")]
    if name == "focus_window":
        command = ["focus", command[1], str(arguments.get("title") or "")]
        if arguments.get("unfullscreen"):
            command.append("--unfullscreen")
        if arguments.get("activate"):
            command.append("--activate")
    try:
        result = subprocess.run([str(WINDOW_HELPER), *command], capture_output=True, text=True, timeout=30,
                                stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"ucu-window could not run ({error}); `ucu install` builds it", True
    return (result.stdout + result.stderr).strip(), result.returncode != 0


def working_folder():
    try:
        return "-".join(Path.cwd().name.split()) or "?"
    except OSError:  # the folder has been deleted
        return "?"


def log_approval(asker, app, action):
    word = {"accept": "allowed", "decline": "denied"}.get(action, "asked about")
    try:
        APPROVAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        if APPROVAL_LOG.exists() and APPROVAL_LOG.stat().st_size > APPROVAL_LOG_LIMIT:
            APPROVAL_LOG.replace(APPROVAL_LOG.with_name(APPROVAL_LOG.name + ".1"))
        with APPROVAL_LOG.open("a") as handle:
            handle.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {asker} {word} {app}\n")
    except OSError:
        pass


def version_key(name):
    return [int(part) if part.isdigit() else -1 for part in name.split(".")]


def entry_problems(entry):
    """List what would keep a plugin's cua_repl entry from starting; empty when it looks launchable."""
    if not isinstance(entry, dict):
        return ["no cua_repl entry"]
    if entry.get("enabled") is False:
        return ["entry is disabled (Codex has not filled in the template yet)"]
    found = []
    command, args, env = entry.get("command") or "", entry.get("args") or [], entry.get("env") or {}
    if not os.path.isabs(command):
        found.append(f"command {command!r} is not an absolute path")
    elif not os.access(command, os.X_OK):
        found.append(f"command {command} is missing or not executable")
    if not args:
        found.append("no args (the launcher script is missing)")
    elif os.path.isabs(args[0]) and not os.path.exists(args[0]):
        found.append(f"launcher {args[0]} is missing")
    repl = env.get("CUA_REPL_NODE_REPL_PATH")
    if not repl or not os.access(repl, os.X_OK):
        found.append(f"CUA_REPL_NODE_REPL_PATH {repl!r} is missing or not executable")
    if not env.get("CUA_REPL_ENABLED_SURFACES"):
        found.append("CUA_REPL_ENABLED_SURFACES is not set")
    return found


def plugin_command():
    """Return (version, command, env) for cua_repl from the newest usable Codex computer-use plugin.

    During an update Codex first writes the plugin's disabled template (`"command": "node"`, no
    args, no env) and fills in the real paths a moment later. Such a version, or one whose paths
    are missing, is skipped for an older one. Raises RuntimeError saying why none is usable.
    """
    versions = sorted((p.name for p in PLUGIN_DIR.iterdir() if (p / ".mcp.json").is_file()),
                      key=version_key, reverse=True) if PLUGIN_DIR.is_dir() else []
    reasons = []
    for version in versions:
        try:
            config = json.loads((PLUGIN_DIR / version / ".mcp.json").read_text())
            entry = config.get("mcpServers", config).get("cua_repl")
        except (OSError, ValueError, AttributeError):  # still being written
            reasons.append(f"{version}: unreadable .mcp.json")
            continue
        issues = entry_problems(entry)
        if not issues:
            return version, [entry["command"], *entry["args"]], entry.get("env") or {}
        reasons.append(f"{version}: {'; '.join(issues)}")
    raise RuntimeError(f"no usable Codex computer-use plugin in {PLUGIN_DIR}"
                       + (f" ({' | '.join(reasons)})" if reasons else ""))


def encode(message):
    return (json.dumps(message) + "\n").encode()


class Proxy:
    def __init__(self, command, turn_idle, stop_grace, stop_idle):
        self.command = command
        self.turn_idle, self.stop_grace, self.stop_idle = turn_idle, stop_grace, stop_idle
        self.session_id = f"claude-code-{uuid.uuid4()}"
        self.turn_number = 1
        self.lock = threading.Lock()        # guards the state below; never held while writing
        self.child_lock = threading.Lock()  # serializes starting, stopping and writing to cua_repl
        self.out_lock = threading.Lock()
        self.child = None                   # the running cua_repl, or None while stopped
        self.initialize = None              # Claude's initialize request and initialized notification,
        self.initialized = None             # replayed to each restarted cua_repl
        self.initialize_key = None          # Claude's pending initialize, whose result gets the usage rules
        self.folder = working_folder()
        self.client_requests = set()  # Claude -> server requests still waiting for a reply
        self.server_requests = set()  # server -> Claude requests (elicitation etc.) still waiting
        self.own_requests = set()     # requests this proxy sent; their replies are dropped
        self.js_calls = set()         # Claude's pending `js` calls, whose results may repeat the documentation
        self.list_calls = set()       # Claude's pending `tools/list` requests, whose results get the window tools
        self.docs_seen = set()        # hashes of documentation blocks this chat has already received
        self.ids = itertools.count(1)
        self.last_activity = time.monotonic()
        self.turn_ended_at = None     # when the last turn ended, if cua_repl has been idle since
        self.turn_has_calls = False   # a tools/call happened since the last turn end
        self.turn_used_browser = False  # a js call this turn touched the browser surface
        self.turn_end_signal = threading.Event()
        self.done = threading.Event()

    # --- message plumbing -------------------------------------------------
    def write_client(self, raw):
        with self.out_lock:
            sys.stdout.buffer.write(raw)
            sys.stdout.buffer.flush()

    @staticmethod
    def write_to(child, raw):
        child.stdin.write(raw)
        child.stdin.flush()

    def fail_requests(self, keys, reason):
        for key in keys:
            self.write_client(encode({"jsonrpc": "2.0", "id": json.loads(key),
                                      "error": {"code": LOCAL_ERROR, "message": reason}}))

    def turn_metadata(self):
        return {"session_id": self.session_id, "turn_id": f"{self.session_id}-turn-{self.turn_number}"}

    def own_call(self, name, arguments):
        """Register and return a proxy-originated tools/call (caller holds self.lock)."""
        request_id = f"ucu-proxy-{next(self.ids)}"
        self.own_requests.add(json.dumps(request_id))
        message = {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                   "params": {"name": name, "arguments": arguments, "_meta": {META_KEY: self.turn_metadata()}}}
        return json.dumps(request_id), encode(message)

    def wait_own(self, key, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                if key not in self.own_requests:
                    return True
            time.sleep(0.02)
        return False

    # --- cua_repl lifecycle (callers hold self.child_lock) ----------------
    def start_child(self):
        """Start cua_repl; return None, or why it could not start."""
        command, env = self.command, None
        try:
            if command is None:
                _version, command, plugin_env = plugin_command()
                env = {**os.environ, **plugin_env}
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        except (RuntimeError, OSError) as error:
            return str(error)
        with self.lock:
            self.child = child  # before from_child starts, so it can tell a crash from a planned stop
            replay = self.initialized is not None
            if replay:
                key = json.dumps(f"ucu-proxy-init-{next(self.ids)}")
                self.own_requests.add(key)
                request = dict(self.initialize, id=json.loads(key))
        threading.Thread(target=self.from_child, args=(child,), daemon=True).start()
        if not replay:
            return None
        try:
            self.write_to(child, encode(request))
            if self.wait_own(key, 30):
                self.write_to(child, self.initialized)
                return None
        except (BrokenPipeError, ValueError, OSError):
            pass
        self.stop_child_locked(force=True)
        return "cua_repl did not answer initialize; try again"

    def stop_child_locked(self, force=False):
        with self.lock:
            if self.child is None or (not force and (self.client_requests or self.server_requests
                                                     or self.own_requests)):
                return
            child, self.child = self.child, None
            self.own_requests.clear()
            self.turn_ended_at = None
        try:
            child.stdin.close()  # cua_repl exits on EOF and takes its kernel and sandboxes with it
        except OSError:
            pass
        try:
            child.wait(5)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()

    def stop_child(self, force=False):
        with self.child_lock:
            self.stop_child_locked(force)

    def forward(self, raw, key, start):
        """Send a Claude message to cua_repl, starting it first if `start`."""
        with self.child_lock:
            if self.child is None:
                if not start:
                    return
                failure = self.start_child()
                if failure:
                    self.fail_own_request(key, f"ucu could not start: {failure}")
                    return
            try:
                self.write_to(self.child, raw)
            except (BrokenPipeError, ValueError, OSError):
                self.fail_own_request(key, "ucu stopped unexpectedly; it restarts on the next call")

    def fail_own_request(self, key, reason):
        with self.lock:
            if key is None or key not in self.client_requests:
                return
            self.client_requests.discard(key)
            self.js_calls.discard(key)
        self.fail_requests([key], reason)

    def drop_repeated_docs(self, message):
        """Re-encode a `js` result whose leading documentation this chat already has (caller holds self.lock)."""
        content = (message.get("result") or {}).get("content")
        first = content[0] if isinstance(content, list) and content else None
        text = first.get("text") if isinstance(first, dict) and first.get("type") == "text" else None
        if not isinstance(text, str) or len(text) < DOCS_MIN_LENGTH or not text.startswith("#"):
            return None
        digest = hashlib.sha256(text.encode()).hexdigest()
        if digest not in self.docs_seen:
            self.docs_seen.add(digest)
            return None
        content[0] = {"type": "text", "text": DOCS_NOTE.format(len(text))}
        return encode(message)

    # --- the two message pumps --------------------------------------------
    def from_client(self):
        for raw in sys.stdin.buffer:
            local_reply, window_call, key, start = None, None, None, True
            with self.lock:
                try:
                    message = json.loads(raw)
                except ValueError:
                    message = None
                if isinstance(message, dict):
                    method = message.get("method")
                    if method == "server/discover" and "id" in message:
                        local_reply = encode({"jsonrpc": "2.0", "id": message["id"], "error": {
                            "code": -32601, "message": "Method not found: server/discover"}})
                    elif method == "ping" and "id" in message and self.child is None:
                        local_reply = encode({"jsonrpc": "2.0", "id": message["id"], "result": {}})
                    elif method == "tools/call" and "id" in message and \
                            (message.get("params") or {}).get("name") in ("list_windows", "focus_window"):
                        window_call = message
                    elif method is not None and "id" in message:
                        key = json.dumps(message["id"])
                        self.client_requests.add(key)
                        if method == "initialize":
                            self.initialize = message
                            self.initialize_key = key
                        elif method == "tools/list":
                            self.list_calls.add(key)
                        elif method == "tools/call":
                            params = message.setdefault("params", {})
                            meta = params.setdefault("_meta", {})
                            meta.setdefault(META_KEY, self.turn_metadata())
                            self.turn_has_calls = True
                            if params.get("name") == "js_reset":
                                self.docs_seen.clear()  # Claude asked for a fresh start: show the docs again
                            if params.get("name") == "js":
                                self.js_calls.add(key)
                                code = str((params.get("arguments") or {}).get("code", ""))
                                if BROWSER_CALL.search(code):
                                    self.turn_used_browser = True
                            raw = encode(message)
                    elif method is None and "id" in message:
                        # Claude answering the server (an approval): only the cua_repl that asked can use it.
                        self.server_requests.discard(json.dumps(message["id"]))
                        start = False
                    else:
                        if method == "notifications/initialized":
                            self.initialized = raw
                        elif method == "notifications/cancelled":
                            self.client_requests.discard(json.dumps((message.get("params") or {}).get("requestId")))
                        start = False
                    self.last_activity = time.monotonic()
                    self.turn_ended_at = None
            if local_reply:
                self.write_client(local_reply)
            elif window_call:
                threading.Thread(target=self.call_window_tool, args=(window_call,), daemon=True).start()
            else:
                self.forward(raw, key, start)
        self.done.set()

    def call_window_tool(self, message):
        params = message.get("params") or {}
        text, failed = run_window_tool(params.get("name"), params.get("arguments") or {})
        self.write_client(encode({"jsonrpc": "2.0", "id": message["id"], "result": {
            "content": [{"type": "text", "text": text}], "isError": failed}}))

    def asker(self):
        """Who an approval is for: the MCP client's name and the folder it runs in."""
        info = ((self.initialize or {}).get("params") or {}).get("clientInfo") or {}
        return "{}:{}".format("-".join(str(info.get("name") or "unknown").split()), self.folder)

    @staticmethod
    def add_instructions(message):
        """Re-encode cua_repl's initialize result with ucu's usage rules after its own instructions."""
        result = message.get("result")
        if not isinstance(result, dict):
            return None
        own = result.get("instructions")
        result["instructions"] = f"{own}\n\n{USAGE_RULES}" if own else USAGE_RULES
        return encode(message)

    @staticmethod
    def add_window_tools(message):
        """Re-encode cua_repl's tools/list result with the window tools added to its last page."""
        result = message.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("tools"), list) or result.get("nextCursor"):
            return None
        result["tools"] = result["tools"] + WINDOW_TOOLS
        return encode(message)

    def answer_child(self, child, request_id, action):
        """Answer a cua_repl request in Claude's place, from a thread so from_child keeps reading."""
        result = {"action": action, "content": {}} if action == "accept" else {"action": action}
        raw = encode({"jsonrpc": "2.0", "id": request_id, "result": result})

        def send():
            with self.child_lock:
                if self.child is child:
                    try:
                        self.write_to(child, raw)
                    except (BrokenPipeError, ValueError, OSError):
                        pass
        threading.Thread(target=send, daemon=True).start()

    def from_child(self, child):
        for raw in child.stdout:
            try:
                message = json.loads(raw)
            except ValueError:
                message = None
            if isinstance(message, dict) and "id" in message:
                if message.get("method") == "elicitation/create":
                    action, app = policy_decision(message.get("params") or {})
                    if app:
                        log_approval(self.asker(), app, action)
                    if action:
                        self.answer_child(child, message["id"], action)
                        continue
                key = json.dumps(message["id"])
                with self.lock:
                    if "method" in message:
                        self.server_requests.add(key)
                    elif key in self.own_requests:
                        self.own_requests.discard(key)
                        continue
                    else:
                        self.client_requests.discard(key)
                        if key in self.js_calls:
                            self.js_calls.discard(key)
                            raw = self.drop_repeated_docs(message) or raw
                        elif key in self.list_calls:
                            self.list_calls.discard(key)
                            raw = self.add_window_tools(message) or raw
                        elif key == self.initialize_key:
                            self.initialize_key = None
                            raw = self.add_instructions(message) or raw
                    self.last_activity = time.monotonic()
            self.write_client(raw)
        with self.lock:
            if self.child is not child:  # stopped on purpose
                return
            self.child = None  # exited on its own: the next request starts a new one
            pending = sorted(self.client_requests)
            self.client_requests.clear()
            self.server_requests.clear()
            self.own_requests.clear()
            self.js_calls.clear()
            self.list_calls.clear()
        self.fail_requests(pending, MAY_HAVE_HAPPENED)
        child.wait()

    # --- turn ends and idle stops -----------------------------------------
    def housekeeping(self):
        while not self.done.is_set():
            signalled = self.turn_end_signal.wait(5)
            self.turn_end_signal.clear()
            own, sky_payload, stop = None, None, False
            with self.lock:
                if self.client_requests or self.server_requests or self.own_requests:
                    continue  # a call or approval is in flight, e.g. from a background agent
                now = time.monotonic()
                idle = now - self.last_activity
                if signalled or (self.turn_has_calls and idle >= self.turn_idle):
                    if self.turn_has_calls:
                        metadata = self.turn_metadata()
                        if self.turn_used_browser and self.child is not None:
                            # loading the browser surface just to notify it costs ~150 MB
                            own = self.own_call("turn_ended", {"hook_event_name": "Stop", **metadata})
                        sky_payload = {"type": "agent-turn-complete", "thread-id": metadata["session_id"],
                                       "turn-id": metadata["turn_id"]}
                        self.turn_number += 1
                        self.turn_has_calls = False
                        self.turn_used_browser = False
                    if self.turn_ended_at is None:  # the grace counts from the first turn end since the last call
                        self.turn_ended_at = now
                if self.child is not None and (idle >= self.stop_idle or (
                        self.turn_ended_at is not None and now - self.turn_ended_at >= self.stop_grace)):
                    stop = own is None
            if sky_payload and os.access(SKY_CLIENT, os.X_OK):
                threading.Thread(target=notify_sky_turn_ended, args=(sky_payload,), daemon=True).start()
            if own:
                key, raw = own
                with self.child_lock:
                    try:
                        if self.child is not None:
                            self.write_to(self.child, raw)
                    except (BrokenPipeError, ValueError, OSError):
                        pass
                if not self.wait_own(key, 10):
                    with self.lock:
                        self.own_requests.discard(key)
                if self.stop_grace <= 0:
                    self.turn_end_signal.set()  # stop on the next pass, now that the browser has detached
            if stop:
                self.stop_child()

    def run(self):
        signal.signal(signal.SIGINFO, lambda _s, _frame: self.turn_end_signal.set())
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, lambda _s, _frame: self.done.set())
        threading.Thread(target=self.from_client, daemon=True).start()
        threading.Thread(target=self.housekeeping, daemon=True).start()
        while not self.done.wait(1):  # the timeout keeps signal handlers running promptly
            pass
        self.stop_child(force=True)
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--turn-idle", type=float, default=120)
    parser.add_argument("--stop-grace", type=float, default=120)
    parser.add_argument("--stop-idle", type=float, default=900)
    parser.add_argument("command", nargs=argparse.REMAINDER, help="cua_repl command (default: the Codex plugin's)")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    code = Proxy(command or None, args.turn_idle, args.stop_grace, args.stop_idle).run()
    # Skip interpreter shutdown: the from_client thread is usually still blocked reading stdin,
    # and finalizing sys.stdin under it aborts with "Fatal Python error: _enter_buffered_busy"
    # (SIGABRT, and a "Python quit unexpectedly" dialog). Every write was already flushed.
    os._exit(code)


if __name__ == "__main__":
    main()
