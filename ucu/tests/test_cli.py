"""`ucu install`, `doctor`, `uninstall` and the deny commands in a temporary HOME.

claude, swiftc and cargo are fakes in $HOME/.local/bin, which ucu searches first, so nothing outside the
temporary HOME is touched, and the real engine in target/release is only copied if it is there.
"""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROXY = str(ROOT / "scripts/ucu-proxy.py")
OTHER_HOOK = {"hooks": [{"type": "command", "command": "afplay done.aiff"}]}
OPENCODE = {"$schema": "https://opencode.ai/config.json", "model": "local/qwen",
            "mcp": {"github": {"type": "remote", "url": "https://example.com/mcp"}}}
POLICY = "Library/Application Support/ucu/policy.json"
CHROME_HOST = "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.ucu.companion.json"

FAKE_CLAUDE = """
config = Path.home() / ".claude.json"
data = json.loads(config.read_text())
servers = data.setdefault("mcpServers", {})
action, name = sys.argv[2], sys.argv[3]
found = servers.pop(name, None) if action == "remove" else True
if action == "add-json":
    servers[name] = json.loads(sys.argv[4])
config.write_text(json.dumps(data))
sys.exit(0 if found else 1)
"""
# `codex mcp add|remove|get --json` on $CODEX_HOME/config.toml, writing each server's table afresh as Codex does.
FAKE_CODEX = """
config = Path(os.environ["CODEX_HOME"]) / "config.toml"
text = config.read_text() if config.exists() else ""
action, name = sys.argv[2], sys.argv[3]
header = f"[mcp_servers.{name}]"
tables, current = {}, None
for line in text.splitlines():
    if line.startswith("["):
        current = line
        tables[current] = []
    elif current:
        tables[current].append(line)
if action == "get":
    if header not in tables:
        sys.exit(f"No MCP server named '{name}' found.")
    values = {key.strip(): json.loads(value) for key, value in (line.split("=", 1) for line in tables[header] if "=" in line)}
    print(json.dumps({"name": name, "transport": {"type": "stdio", "command": values.get("command"),
                      "args": values.get("args")}, "tool_timeout_sec": values.get("tool_timeout_sec")}))
    sys.exit(0)
tables.pop(header, None)
if action == "add":
    command = sys.argv[sys.argv.index("--") + 1:]
    tables[header] = [f"command = {json.dumps(command[0])}", f"args = {json.dumps(command[1:])}"]
config.parent.mkdir(parents=True, exist_ok=True)
config.write_text("".join(f"{key}\\n" + "".join(f"{line}\\n" for line in lines) for key, lines in tables.items()))
"""
FAKE_SWIFTC = """
out = Path(sys.argv[sys.argv.index("-o") + 1])
out.write_text("#!/bin/sh\\nexit 0\\n")
out.chmod(0o755)
"""


FAKE_CARGO = """
if Path.home().joinpath("no-rust").exists():
    sys.exit("error: no rust")
built = Path.home() / "target/release/agent-desktop"
built.parent.mkdir(parents=True, exist_ok=True)
built.write_text("#!/bin/sh\\necho version\\n")
built.chmod(0o755)
"""


class CliTest(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.home = Path(home.name)
        bin_dir = self.home / ".local/bin"
        bin_dir.mkdir(parents=True)
        for name, body in (("claude", FAKE_CLAUDE), ("codex", FAKE_CODEX), ("swiftc", FAKE_SWIFTC),
                           ("cargo", FAKE_CARGO)):
            path = bin_dir / name
            path.write_text(f"#!{sys.executable}\nimport json, os, sys\nfrom pathlib import Path\n" + body)
            path.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.home), "PATH": f"{bin_dir}:/usr/bin:/bin",
                    "CARGO_TARGET_DIR": str(self.home / "target"), "CODEX_HOME": str(self.home / ".codex"),
                    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
                    "GIT_COMMITTER_EMAIL": "test@example.com"}
        self.assertEqual(shutil.which("claude", path=self.env["PATH"]), str(bin_dir / "claude"))
        self.updates_off = self.home / "Library/Application Support/ucu/no-auto-update"
        self.updates_off.parent.mkdir(parents=True)
        self.updates_off.touch()  # the servers that install and doctor start would update the clone tests run from

        (self.home / ".claude.json").write_text(json.dumps({"mcpServers": {"other": {"command": "x"}}, "numStartups": 3}))
        (self.home / ".claude").mkdir()
        (self.home / ".claude/settings.json").write_text(
            json.dumps({"model": "opus", "hooks": {"Stop": [OTHER_HOOK]}}, indent=2))

    def opencode(self):
        (self.home / ".config/opencode").mkdir(parents=True)
        (self.home / ".config/opencode/opencode.json").write_text(json.dumps(OPENCODE, indent=2) + "\n")

    def read_json(self, relative):
        return json.loads((self.home / relative).read_text())

    def ucu(self, *args):
        result = subprocess.run([sys.executable, str(ROOT / "ucu"), *args], capture_output=True, text=True, env=self.env)
        return result.returncode, result.stdout + result.stderr

    def stop_hooks(self):
        return self.read_json(".claude/settings.json")["hooks"]["Stop"]

    def codex_servers(self):
        config = self.home / ".codex/config.toml"
        text = config.read_text() if config.exists() else ""
        return [line[len("[mcp_servers."):-1] for line in text.splitlines() if line.startswith("[mcp_servers.")]

    def test_install_doctor_uninstall(self):
        self.opencode()
        (self.home / CHROME_HOST).parent.parent.mkdir(parents=True)  # Chrome is set up
        code, output = self.ucu("install", "--python", sys.executable)
        self.assertEqual(code, 0, output)

        servers = self.read_json(".claude.json")["mcpServers"]
        self.assertEqual(sorted(servers), ["other", "ucu"])
        self.assertEqual(servers["ucu"], {"type": "stdio", "command": sys.executable, "args": ["-I", PROXY], "env": {},
                                          "timeout": 300000, "alwaysLoad": True})
        self.assertEqual(self.read_json(".claude/settings.json")["model"], "opus")
        self.assertEqual(self.stop_hooks()[0], OTHER_HOOK)
        self.assertEqual(self.stop_hooks()[1]["hooks"][0]["command"], 'pkill -INFO -P "$PPID" -f ucu-proxy.py; exit 0')
        self.assertEqual(self.read_json(".config/opencode/opencode.json"), {**OPENCODE, "mcp": {
            **OPENCODE["mcp"], "ucu": {"type": "local", "command": [sys.executable, "-I", PROXY], "enabled": True}}})
        self.assertEqual((self.home / ".codex/config.toml").read_text(),
                         f'[mcp_servers.ucu]\ntool_timeout_sec = 300\ncommand = "{sys.executable}"\n'
                         f'args = ["-I", "{PROXY}"]\n')
        self.assertIn("ucu is set up for Claude Code and Codex and opencode", output)
        self.assertFalse((self.home / ".claude/CLAUDE.md").exists())  # no rule unless asked
        policy = self.read_json(POLICY)
        self.assertIn("Keychain Access", policy["deny"])
        self.assertNotIn("allow", policy)
        backup = next((self.home / "Library/Application Support/ucu/backups").iterdir())
        self.assertEqual(json.loads((backup / "opencode.json").read_text()), OPENCODE)
        self.assertTrue((self.home / ".local/bin/ucu-window").exists())
        self.assertTrue((self.home / ".local/bin/ucu-engine").exists())
        host = self.read_json(CHROME_HOST)
        self.assertEqual((host["name"], host["allowed_origins"]),
                         ("com.ucu.companion", ["chrome-extension://ddfnafenkalcehfggkpmlehmnamkonlp/"]))
        self.assertTrue(os.access(host["path"], os.X_OK))
        self.assertIn(str(ROOT / "scripts/ucu-chrome-host.py"), Path(host["path"]).read_text())

        edited = {"deny": ["Mail"]}
        (self.home / POLICY).write_text(json.dumps(edited))
        code, output = self.ucu("install", "--python", sys.executable)  # again: nothing doubles up
        self.assertEqual(code, 0, output)
        self.assertEqual(len(self.stop_hooks()), 2)
        self.assertEqual(self.read_json(POLICY), edited)

        code, output = self.ucu("doctor")
        self.assertEqual(code, 0, output)
        self.assertIn("the approval policy denies 1 apps and approves every other app", output)
        self.assertNotIn("✗", output)

        log = self.home / "Library/Logs/ucu/focus.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        now, old = time.strftime("%Y-%m-%d %H:%M:%S"), "2020-01-01 10:00:00"
        put_back = "Google Chrome came forward over Mail, as it came by itself: put back"
        log.write_text(f"{old} a:b {put_back}\n{now} a:b {put_back}\n"
                       f"{now} a:b Blender came forward over Mail: left in front, as the user clicked\n")
        code, output = self.ucu("doctor")
        self.assertIn("apps came forward 2 times during agent work, and ucu gave the user's app back once; it left "
                      "them in front once", output)

        code, output = self.ucu("uninstall")
        self.assertEqual(code, 0, output)
        self.assertEqual(self.read_json(".claude.json")["mcpServers"], {"other": {"command": "x"}})
        self.assertEqual(self.read_json(".claude/settings.json"), {"model": "opus", "hooks": {"Stop": [OTHER_HOOK]}})
        self.assertEqual(self.read_json(".config/opencode/opencode.json"), OPENCODE)
        self.assertEqual(self.codex_servers(), [])
        self.assertFalse((self.home / "Library/Application Support/ucu/install.json").exists())
        self.assertFalse((self.home / ".local/bin/ucu-window").exists())
        self.assertFalse((self.home / CHROME_HOST).exists())
        self.assertFalse((self.home / ".local/bin/ucu-chrome-host").exists())
        self.assertEqual(self.read_json(POLICY), edited)

        code, output = self.ucu("doctor")
        self.assertEqual(code, 1, output)

    def test_install_on_a_mac_with_no_claude_settings_or_opencode(self):
        (self.home / ".claude/settings.json").unlink()
        code, output = self.ucu("install", "--python", sys.executable, "--clients", "claude")
        self.assertEqual(code, 0, output)
        self.assertEqual(len(self.stop_hooks()), 1)
        self.assertFalse((self.home / ".config/opencode").exists())
        self.assertFalse((self.home / "Library/Application Support/Google").exists())  # nor Chrome

    def test_install_finds_cargo_where_rustup_puts_it(self):
        cargo_home = self.home / ".cargo/bin"
        cargo_home.mkdir(parents=True)
        (self.home / ".local/bin/cargo").rename(cargo_home / "cargo")  # not on PATH, as before a new shell
        rustup = self.home / ".local/bin/rustup"  # found before a real one, which could install a toolchain
        rustup.write_text("#!/bin/sh\nexit 1\n")
        rustup.chmod(0o755)
        code, output = self.ucu("install", "--python", sys.executable)
        self.assertEqual(code, 0, output)
        self.assertTrue((self.home / ".local/bin/ucu-engine").exists())

    @unittest.skipIf(any(os.access(f"{folder}/{name}", os.X_OK) for folder in ("/opt/homebrew/bin", "/usr/local/bin")
                         for name in ("claude", "codex", "opencode")),
                     "a claude, codex or opencode command in /opt/homebrew/bin or /usr/local/bin can't be hidden from ucu")
    def test_install_with_no_agent_and_for_the_one_found(self):
        (self.home / ".local/bin/claude").unlink()
        (self.home / ".local/bin/codex").unlink()
        code, output = self.ucu("install", "--python", sys.executable)
        self.assertEqual(code, 1, output)
        self.assertIn("no agent was found", output)
        self.assertFalse((self.home / ".local/bin/ucu-engine").exists())

        self.opencode()
        code, output = self.ucu("install", "--python", sys.executable)
        self.assertEqual(code, 0, output)
        self.assertIn("ucu is set up for opencode.", output)
        self.assertEqual(self.read_json(".config/opencode/opencode.json")["mcp"]["ucu"]["command"][1:], ["-I", PROXY])

    def test_install_for_the_agents_chosen_and_remember_them(self):
        self.opencode()
        code, output = self.ucu("install", "--python", sys.executable, "--clients", "opencode")
        self.assertEqual(code, 0, output)
        self.assertIn("ucu is set up for opencode.", output)
        self.assertEqual(sorted(self.read_json(".claude.json")["mcpServers"]), ["other"])
        self.assertEqual(self.stop_hooks(), [OTHER_HOOK])
        self.assertEqual(self.codex_servers(), [])
        self.assertEqual(self.read_json(".config/opencode/opencode.json")["mcp"]["ucu"]["command"][1:], ["-I", PROXY])
        code, output = self.ucu("doctor")
        self.assertEqual(code, 0, output)  # Claude Code wasn't chosen, so its missing setup is no problem
        self.assertIn("ucu is set up for opencode", output)
        self.assertIn("the server answers an MCP initialize", output)
        self.assertNotIn("Stop hook", output)

        code, output = self.ucu("install", "--python", sys.executable)  # again, with no --clients: the same choice
        self.assertEqual(code, 0, output)
        self.assertEqual(self.codex_servers(), [])

        code, output = self.ucu("install", "--python", sys.executable, "--clients", "Claude-Code,codex")
        self.assertEqual(code, 0, output)
        self.assertEqual(sorted(self.read_json(".claude.json")["mcpServers"]), ["other", "ucu"])
        self.assertEqual(self.codex_servers(), ["ucu"])
        self.assertNotIn("ucu", self.read_json(".config/opencode/opencode.json")["mcp"])  # no longer chosen

        code, output = self.ucu("install", "--python", sys.executable, "--clients", "all")
        self.assertEqual(code, 0, output)
        self.assertIn("ucu", self.read_json(".config/opencode/opencode.json")["mcp"])

        code, output = self.ucu("install", "--python", sys.executable, "--clients", "cursor")
        self.assertEqual(code, 1, output)
        self.assertIn("--clients takes `all` or a list of claude, codex, opencode", output)

    @unittest.skipIf(any(os.access(f"{folder}/claude", os.X_OK) for folder in ("/opt/homebrew/bin", "/usr/local/bin")),
                     "a claude command in /opt/homebrew/bin or /usr/local/bin can't be hidden from ucu")
    def test_an_agent_chosen_that_is_not_here_changes_nothing(self):
        (self.home / ".local/bin/claude").unlink()
        code, output = self.ucu("install", "--python", sys.executable, "--clients", "codex,claude")
        self.assertEqual(code, 1, output)
        self.assertIn("Claude Code was not found on this Mac", output)
        self.assertEqual(self.codex_servers(), [])
        self.assertFalse((self.home / ".local/bin/ucu-engine").exists())

    def test_the_global_rule_goes_in_each_file_once_and_comes_out_cleanly(self):
        self.opencode()
        claude_md = self.home / ".claude/CLAUDE.md"
        mine = "# My rules\n\nBe brief.\n"
        claude_md.write_text(mine)
        (self.home / ".codex").mkdir()
        (self.home / ".codex/AGENTS.md").symlink_to(claude_md)  # one file for both, as many people keep it
        code, output = self.ucu("install", "--python", sys.executable, "--rule", "global")
        self.assertEqual(code, 0, output)
        text = claude_md.read_text()
        self.assertTrue(text.startswith(mine + "\n<!-- ucu:start -->\nUse the `ucu` MCP server"), text)
        self.assertEqual(text.count("<!-- ucu:start -->"), 1)
        self.assertTrue((self.home / ".codex/AGENTS.md").is_symlink())
        opencode_md = self.home / ".config/opencode/AGENTS.md"
        self.assertTrue(opencode_md.read_text().startswith("<!-- ucu:start -->"))
        backup = next((self.home / "Library/Application Support/ucu/backups").iterdir())
        self.assertEqual((backup / "files" / claude_md.resolve().relative_to("/")).read_text(), mine)

        text += "\nWritten after the rule.\n"
        claude_md.write_text(text)
        code, output = self.ucu("install", "--python", sys.executable)  # again: the choice stays, nothing moves
        self.assertEqual(code, 0, output)
        self.assertEqual(claude_md.read_text(), text)
        code, output = self.ucu("doctor")
        self.assertEqual(code, 0, output)
        self.assertIn(f"the rule to use ucu is in {claude_md.resolve()}", output)

        code, output = self.ucu("install", "--python", sys.executable, "--clients", "claude,codex")
        self.assertEqual(code, 0, output)
        self.assertFalse(opencode_md.exists())  # it held only the rule, for an agent no longer chosen
        self.assertEqual(claude_md.read_text(), text)

        code, output = self.ucu("install", "--python", sys.executable, "--rule", "none")
        self.assertEqual(code, 0, output)
        self.assertEqual(claude_md.read_text(), mine + "\nWritten after the rule.\n")
        self.assertTrue((self.home / ".codex/AGENTS.md").is_symlink())

    def test_the_rule_in_a_project_and_uninstall_takes_it_out(self):
        code, output = self.ucu("install", "--python", sys.executable)
        self.assertEqual(code, 0, output)
        project = self.home / "my project"
        project.mkdir()
        theirs = "# Agents\n\nRun the tests.\n"
        (project / "AGENTS.md").write_text(theirs)
        code, output = self.ucu("rule", "add", str(project))
        self.assertEqual(code, 0, output)
        self.assertEqual((project / "CLAUDE.md").read_text().count("<!-- ucu:start -->"), 1)
        self.assertTrue((project / "AGENTS.md").read_text().startswith(theirs + "\n<!-- ucu:start -->"))
        self.assertFalse((self.home / ".claude/CLAUDE.md").exists())  # only the project

        code, output = self.ucu("rule", "remove", str(project))
        self.assertEqual(code, 0, output)
        self.assertEqual((project / "AGENTS.md").read_text(), theirs)
        self.assertFalse((project / "CLAUDE.md").exists())

        self.assertEqual(self.ucu("rule", "add", "--global", str(project))[0], 0)
        self.assertIn("<!-- ucu:start -->", (self.home / ".claude/CLAUDE.md").read_text())
        code, output = self.ucu("uninstall")
        self.assertEqual(code, 0, output)
        self.assertEqual((project / "AGENTS.md").read_text(), theirs)
        self.assertFalse((project / "CLAUDE.md").exists())
        self.assertFalse((self.home / ".claude/CLAUDE.md").exists())

        code, output = self.ucu("rule", "add")
        self.assertEqual(code, 1, output)
        self.assertIn("name --global, a project folder, or both", output)

    def test_deny_allow_and_denied(self):
        self.assertEqual(self.ucu("denied")[1].strip(), "No apps are denied: every app is approved.")
        self.assertEqual(self.ucu("deny", "Mail")[0], 0)
        self.assertEqual(self.ucu("deny", "mail")[0], 0)  # the same app: no duplicate
        self.assertEqual(self.ucu("deny", "Messages")[0], 0)
        self.assertEqual(self.read_json(POLICY)["deny"], ["mail", "Messages"])
        self.assertEqual(self.ucu("allow", "MAIL")[0], 0)
        self.assertEqual(self.ucu("denied")[1].strip(), "Messages")

    def test_deny_keeps_a_broken_policy_as_it_was(self):
        (self.home / POLICY).write_text("{")
        code, output = self.ucu("deny", "Mail")
        self.assertEqual(code, 1, output)
        self.assertEqual((self.home / POLICY).read_text(), "{")

    # --- update: a throwaway repository with a copy of ucu/ and a stand-in for the engine's code, and a clone of it
    def git(self, folder, *args):
        result = subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=True, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def clone(self):
        origin = self.home / "origin"
        shutil.copytree(ROOT, origin / "ucu", ignore=shutil.ignore_patterns("tests", "__pycache__", "assets", "benchmarks"))
        (origin / "Cargo.toml").write_text("[workspace]\n")
        self.git(origin, "init", "-q", "-b", "ucu")
        self.git(origin, "add", "-A")
        self.git(origin, "commit", "-q", "-m", "first")
        self.git(self.home, "clone", "-q", str(origin), "clone")
        return origin, self.home / "clone"

    def commit(self, folder, path, text):
        (folder / path).write_text(text)
        self.git(folder, "commit", "-q", "-am", f"change {path}")

    def update(self, clone, *args):
        result = subprocess.run([sys.executable, str(clone / "ucu/ucu"), "update", *args], capture_output=True,
                                text=True, env=self.env)
        return result.returncode, result.stdout + result.stderr

    def same(self, origin, clone):
        return self.git(origin, "rev-parse", "HEAD") == self.git(clone, "rev-parse", "HEAD")

    def test_update_fast_forwards_and_rebuilds_only_what_changed(self):
        origin, clone = self.clone()
        engine, helper = self.home / ".local/bin/ucu-engine", self.home / ".local/bin/ucu-window"
        self.assertEqual(self.update(clone), (0, "✓ ucu is up to date\n"))

        self.commit(origin, "ucu/README.md", "new words\n")
        code, output = self.update(clone)
        self.assertEqual(code, 0, output)
        self.assertTrue(self.same(origin, clone))
        self.assertFalse(engine.exists() or helper.exists(), output)  # only ucu/ changed: nothing to build

        self.commit(origin, "Cargo.toml", "[workspace]\nmembers = []\n")
        self.commit(origin, "ucu/native/ucu-window.swift", "// new\n")
        code, output = self.update(clone)
        self.assertEqual(code, 0, output)
        self.assertTrue(self.same(origin, clone))
        self.assertTrue(engine.exists() and helper.exists(), output)

    def test_update_leaves_local_changes_and_commits_alone(self):
        origin, clone = self.clone()
        self.commit(origin, "ucu/README.md", "theirs\n")
        (clone / "ucu/README.md").write_text("mine\n")
        code, output = self.update(clone)
        self.assertEqual(code, 1, output)
        self.assertIn("this clone has local changes, so it was left as it is", output)
        self.commit(clone, "ucu/README.md", "mine\n")
        code, output = self.update(clone)
        self.assertEqual(code, 1, output)
        self.assertIn("this clone has commits that origin/ucu doesn't", output)
        self.assertEqual((clone / "ucu/README.md").read_text(), "mine\n")

    def test_update_goes_back_when_the_engine_does_not_build(self):
        origin, clone = self.clone()
        before = self.git(clone, "rev-parse", "HEAD")
        (self.home / "no-rust").touch()
        self.commit(origin, "Cargo.toml", "[workspace]\nmembers = []\n")
        code, output = self.update(clone)
        self.assertEqual(code, 1, output)
        self.assertIn("went back to the version before the update", output)
        self.assertEqual(self.git(clone, "rev-parse", "HEAD"), before)
        self.assertEqual(self.git(clone, "status", "--porcelain", "--untracked-files=no"), "")

    def test_chats_update_one_at_a_time_and_at_most_every_ten_minutes(self):
        origin, clone = self.clone()
        state = self.home / "Library/Application Support/ucu"
        self.updates_off.unlink()
        self.commit(origin, "ucu/README.md", "one\n")
        self.assertEqual(self.update(clone, "--auto"), (0, ""))
        self.assertTrue(self.same(origin, clone))
        self.assertIn("✓ updated to", (self.home / "Library/Logs/ucu/update.log").read_text())

        self.commit(origin, "ucu/README.md", "two\n")
        self.update(clone, "--auto")  # the last check was just now
        self.assertFalse(self.same(origin, clone))
        os.utime(state / "update-checked", (0, 0))
        with (state / "update.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)  # another chat is updating
            self.update(clone, "--auto")
        self.assertFalse(self.same(origin, clone))
        self.updates_off.touch()
        self.update(clone, "--auto")
        self.assertFalse(self.same(origin, clone))
        self.updates_off.unlink()
        self.update(clone, "--auto")
        self.assertTrue(self.same(origin, clone))

    def test_install_changes_nothing_when_the_engine_does_not_build(self):
        (self.home / "no-rust").touch()
        code, output = self.ucu("install", "--python", sys.executable)
        self.assertEqual(code, 1, output)
        self.assertIn("could not build the engine", output)
        self.assertEqual(sorted(self.read_json(".claude.json")["mcpServers"]), ["other"])
        self.assertEqual(self.stop_hooks(), [OTHER_HOOK])


if __name__ == "__main__":
    unittest.main()
