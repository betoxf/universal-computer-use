"""install.sh, the one-line installer, in a temporary HOME with a PATH of its own.

PATH holds only the commands a test gives it, so a missing git or python3 can be tested. claude, swiftc and cargo are
the fakes test_cli uses, in $HOME/.local/bin, and the clone comes from a throwaway repository with a copy of ucu/.
The script runs in a session of its own, so it has no terminal to ask in, as under `curl | bash` with no TTY.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from test_cli import FAKE_CARGO, FAKE_CLAUDE, FAKE_SWIFTC  # noqa: E402

SCRIPT = ROOT / "install.sh"
SYSTEM = "/usr/bin:/bin"
TOOLS = ("cat", "dirname", "ls", "mkdir", "sh", "git")
OPENCODE = {"$schema": "https://opencode.ai/config.json"}


class InstallScriptTest(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.home = Path(home.name).resolve()
        self.bin = self.home / "path"
        self.bin.mkdir()
        for name in TOOLS:
            (self.bin / name).symlink_to(shutil.which(name, path=SYSTEM))
        (self.bin / "python3").symlink_to(sys.executable)
        self.fake("uname", 'echo Darwin')
        self.fake("xcode-select", 'echo /Library/Developer/CommandLineTools')
        self.local = self.home / ".local/bin"
        self.local.mkdir(parents=True)
        for name, body in (("claude", FAKE_CLAUDE), ("swiftc", FAKE_SWIFTC), ("cargo", FAKE_CARGO)):
            self.python_fake(self.local / name, body)
        self.env = {"HOME": str(self.home), "PATH": str(self.bin), "CARGO_TARGET_DIR": str(self.home / "target"),
                    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
                    "GIT_COMMITTER_EMAIL": "test@example.com", "LANG": "en_US.UTF-8"}
        updates_off = self.home / "Library/Application Support/ucu/no-auto-update"
        updates_off.parent.mkdir(parents=True)
        updates_off.touch()  # the servers that install and doctor start would update the clone
        (self.home / ".claude.json").write_text(json.dumps({"mcpServers": {}}))
        self.clone = self.home / ".ucu"

    def fake(self, name, body):
        path = self.bin / name
        path.unlink(missing_ok=True)
        path.write_text(f"#!/bin/sh\necho \"$0 $*\" >> \"$HOME/calls\"\n{body}\n")
        path.chmod(0o755)

    def python_fake(self, path, body):
        path.write_text(f"#!{sys.executable}\nimport json, sys\nfrom pathlib import Path\n" + body)
        path.chmod(0o755)

    def calls(self):
        log = self.home / "calls"
        return log.read_text() if log.exists() else ""

    def install(self, *args, **env):
        result = subprocess.run(["/bin/bash", str(SCRIPT), *args], capture_output=True, text=True,
                                env={**self.env, **env}, stdin=subprocess.DEVNULL, start_new_session=True, timeout=120)
        return result.returncode, result.stdout + result.stderr

    def git(self, folder, *args):
        result = subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=True, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def origin(self):
        origin = self.home / "origin"
        skip = shutil.ignore_patterns("tests", "__pycache__", "assets", "benchmarks")
        shutil.copytree(ROOT, origin / "ucu", ignore=skip)
        (origin / "Cargo.toml").write_text("[workspace]\n")
        self.git(origin, "init", "-q", "-b", "main")
        self.git(origin, "add", "-A")
        self.git(origin, "commit", "-q", "-m", "first")
        self.env["UCU_REPO"] = str(origin)
        return origin

    def registered(self):
        return json.loads((self.home / ".claude.json").read_text())["mcpServers"].get("ucu")

    def assert_nothing_installed(self):
        self.assertFalse(self.clone.exists())
        self.assertIsNone(self.registered())

    def test_help_and_unknown_options(self):
        code, output = self.install("--help")
        self.assertEqual(code, 0, output)
        self.assertIn("UCU_DIR", output)
        code, output = self.install("--frobnicate")
        self.assertEqual(code, 2, output)
        self.assertIn("unknown option: --frobnicate", output)
        self.assertEqual(self.calls(), "")

    def test_only_on_macos(self):
        self.fake("uname", "echo Linux")
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("UCU runs on macOS only", output)

    def test_without_the_command_line_tools_git_and_python_are_not_run(self):
        self.fake("xcode-select", "exit 2")
        (self.bin / "git").unlink()
        (self.bin / "python3").unlink()
        self.fake("git", "exit 1")
        self.fake("python3", "exit 1")
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("xcode-select --install", output)
        self.assertNotIn("git", self.calls().replace("xcode-select", ""))
        self.assertNotIn("python3", self.calls())

    def test_needs_python_3_9_and_git(self):
        (self.bin / "python3").unlink()
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("python3 was not found", output)
        self.fake("python3", "exit 1")
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("is older than Python 3.9", output)
        (self.bin / "python3").unlink()
        (self.bin / "python3").symlink_to(sys.executable)
        (self.bin / "git").unlink()
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("git was not found", output)
        self.assert_nothing_installed()

    def test_needs_claude_code_or_opencode(self):
        (self.local / "claude").unlink()
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("neither Claude Code (the claude command) nor opencode", output)
        self.assert_nothing_installed()

    def test_without_rust_or_a_terminal_it_explains_and_stops(self):
        (self.local / "cargo").unlink()
        self.fake("curl", "exit 1")
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("there is no terminal to ask in", output)
        self.assertIn("| bash -s -- --yes", output)
        self.assertNotIn("curl", self.calls())
        self.assert_nothing_installed()

    def test_yes_installs_rust_then_ucu(self):
        self.origin()
        cargo = self.local / "cargo"
        cargo.rename(self.home / "rustup-cargo")
        rustup = f'/bin/mkdir -p "$HOME/.cargo/bin" && /bin/cp "{self.home}/rustup-cargo" "$HOME/.cargo/bin/cargo"'
        self.fake("curl", f"echo '{rustup}; echo \"rustup $*\"'")
        code, output = self.install("--yes")
        self.assertEqual(code, 0, output)
        self.assertIn("https://sh.rustup.rs", self.calls())
        self.assertIn("rustup -y --profile minimal", output)
        self.assertIn("✓ installed Rust", output)
        self.assertEqual(self.registered()["args"], ["-I", str(self.clone / "ucu/scripts/ucu-proxy.py")])
        self.assertEqual(self.registered()["command"], str(self.bin / "python3"))
        self.assertTrue((self.home / ".local/bin/ucu-engine").exists())
        self.assertIn("Next steps:", output)
        self.assertNotIn("✗", output)
        self.assertNotIn("doctor found something to fix", output)

    def test_runs_again_updates_a_clean_clone_and_leaves_local_changes(self):
        origin = self.origin()
        code, output = self.install(UCU_YES="1")
        self.assertEqual(code, 0, output)
        code, output = self.install()
        self.assertEqual(code, 0, output)
        self.assertIn("UCU is already cloned at", output)
        self.assertIn("ucu is up to date", output)

        (origin / "ucu/README.md").write_text("new words\n")
        self.git(origin, "commit", "-q", "-am", "new words")
        code, output = self.install()
        self.assertEqual(code, 0, output)
        self.assertEqual((self.clone / "ucu/README.md").read_text(), "new words\n")

        (origin / "ucu/README.md").write_text("newer words\n")
        self.git(origin, "commit", "-q", "-am", "newer words")
        (self.clone / "ucu/README.md").write_text("mine\n")
        code, output = self.install()
        self.assertEqual(code, 0, output)
        self.assertIn("this clone has local changes, so it was left as it is", output)
        self.assertIn(f"installing the clone at {self.clone} as it is", output)
        self.assertEqual((self.clone / "ucu/README.md").read_text(), "mine\n")
        self.assertIsNotNone(self.registered())

    def test_a_folder_that_is_not_a_clone_is_left_alone(self):
        self.origin()
        self.clone.mkdir()
        (self.clone / "notes.txt").write_text("mine\n")
        code, output = self.install()
        self.assertEqual(code, 1, output)
        self.assertIn("exists and isn't a clone of UCU", output)
        self.assertEqual(os.listdir(self.clone), ["notes.txt"])

    def test_installed_from_another_folder_changes_nothing(self):
        other = self.home / "Projects/universal-computer-use"
        (other / "ucu/scripts").mkdir(parents=True)
        (other / "ucu/scripts/ucu-proxy.py").write_text("")
        proxy = str(other / "ucu/scripts/ucu-proxy.py")
        config = {"mcpServers": {"ucu": {"command": "python3", "args": ["-I", proxy]}}}
        (self.home / ".claude.json").write_text(json.dumps(config))
        code, output = self.install()
        self.assertEqual(code, 0, output)
        self.assertIn(f"UCU is already installed from {other}, so nothing was changed", output)
        self.assertFalse(self.clone.exists())
        self.assertEqual(json.loads((self.home / ".claude.json").read_text()), config)

    def test_opencode_only(self):
        self.origin()
        (self.local / "claude").unlink()
        opencode = self.home / ".config/opencode/opencode.json"
        opencode.parent.mkdir(parents=True)
        opencode.write_text(json.dumps(OPENCODE))
        code, output = self.install()
        self.assertEqual(code, 0, output)
        self.assertIn("UCU will be set up for opencode only", output)
        self.assertIn("ucu was set up for opencode only", output)
        self.assertEqual(json.loads(opencode.read_text())["mcp"]["ucu"]["command"][1:],
                         ["-I", str(self.clone / "ucu/scripts/ucu-proxy.py")])
        self.assertIsNone(self.registered())
        self.assertFalse((self.home / ".claude/settings.json").exists())
        self.assertNotIn("✗", output)
        self.assertIn("the server answers an MCP initialize", output)

    def test_uninstall_keeps_the_clone(self):
        self.origin()
        self.assertEqual(self.install()[0], 0)
        code, output = self.install("--uninstall")
        self.assertEqual(code, 0, output)
        self.assertIsNone(self.registered())
        self.assertFalse((self.home / ".local/bin/ucu-engine").exists())
        self.assertTrue((self.clone / "ucu/ucu").exists())
        self.assertIn(f'rm -rf "{self.clone}"', output)


if __name__ == "__main__":
    unittest.main()
