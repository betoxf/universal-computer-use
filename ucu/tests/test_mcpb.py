"""mcpb/launch.py from a bundle laid out as mcpb/pack-mcpb.sh lays it out, in a temporary HOME.

The bundle's engine and ucu-window are tests/fake_engine.py and tests/fake_ucu_window.py, and HOME has no
~/.local/bin, so every call that reaches them went to the bundle's own copies.
"""
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
POLICY = "Library/Application Support/ucu/policy.json"


def stage_bundle(server):
    (server / "bin").mkdir(parents=True)
    (server / "ucu/scripts").mkdir(parents=True)
    (server / "ucu/native").mkdir(parents=True)
    shutil.copy(ROOT / "mcpb/launch.py", server / "launch.py")
    shutil.copy(ROOT / "ucu", server / "ucu/ucu")
    shutil.copy(ROOT / "scripts/ucu-proxy.py", server / "ucu/scripts/ucu-proxy.py")
    shutil.copy(ROOT / "native/browser.js", server / "ucu/native/browser.js")
    for name, fake in (("ucu-engine", "fake_engine.py"), ("ucu-window", "fake_ucu_window.py")):
        path = server / "bin" / name
        path.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{TESTS / fake}" "$@"\n')
        path.chmod(0o755)


class BundleTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.home = self.root / "home"
        self.home.mkdir()
        stage_bundle(self.root / "bundle/server")
        self.engine_log = self.root / "engine.log"
        self.window_log = self.root / "window.log"
        env = {**os.environ, "HOME": str(self.home), "FAKE_ENGINE_LOG": str(self.engine_log),
               "FAKE_WINDOW_LOG": str(self.window_log), "FAKE_WINDOW_REPORTS": str(self.root / "reports"),
               "FAKE_ALERTS": str(self.root / "alerts")}
        self.process = subprocess.Popen([sys.executable, "-I", str(self.root / "bundle/server/launch.py")],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, cwd=self.home)
        self.addCleanup(self.close)
        self.lines = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.ids = iter(range(1, 1000))

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()

    def read(self):
        for line in self.process.stdout:
            self.lines.put(line)

    def request(self, method, params=None):
        request_id = next(self.ids)
        message = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()
        while True:
            reply = json.loads(self.lines.get(timeout=15))  # stdout carries nothing but JSON-RPC
            if reply.get("id") == request_id:
                return reply

    def initialize(self):
        return self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                           "clientInfo": {"name": "test client", "version": "1"}})

    def test_seeds_the_default_policy_and_uses_the_bundled_binaries(self):
        self.assertIn("result", self.initialize())
        policy = json.loads((self.home / POLICY).read_text())
        self.assertIn("System Settings", policy["deny"])
        self.assertIn("look", {tool["name"] for tool in self.request("tools/list")["result"]["tools"]})
        self.request("tools/call", {"name": "look", "arguments": {"app": "Calculator"}})
        self.assertTrue(self.engine_log.exists(), "the bundled engine was not run")
        self.request("tools/call", {"name": "list_windows", "arguments": {"app": "Calculator"}})
        self.assertTrue(self.window_log.exists(), "the bundled ucu-window was not run")
        self.assertFalse((self.home / ".local/bin").exists())

    def test_keeps_an_existing_policy(self):
        path = self.home / POLICY
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"deny": ["Calculator"]}))
        self.initialize()
        self.assertEqual(json.loads(path.read_text()), {"deny": ["Calculator"]})

    def test_does_not_update_itself(self):
        self.initialize()
        checked = self.home / "Library/Application Support/ucu/update-checked"
        deadline = time.time() + 5  # a check runs in the background and takes a moment to start
        while time.time() < deadline and not checked.exists():
            time.sleep(0.1)
        self.assertFalse(checked.exists())
        self.assertFalse((self.home / "Library/Logs/ucu/update.log").exists())


if __name__ == "__main__":
    unittest.main()
