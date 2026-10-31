# Universal Computer Use

`ucu` lets Claude Code, opencode and other MCP clients operate your Mac's apps in the background, through
the Computer Use engine that comes with the ChatGPT desktop app.

- Agents click, type and read other apps without moving your pointer or taking focus.
- It works in apps with no useful accessibility tree too, by clicking at screen positions in a background
  window. Some remote-desktop and canvas apps ignore background input.
- Agents can use every app except the ones you deny.
- Every approval is logged with the agent and folder that caused it.
- A Codex update needs nothing from you: `ucu` finds the newest engine each time it starts it.

macOS only.

## Before you use it

- **This is an unofficial project.** It is not made by, affiliated with, or endorsed by OpenAI or Anthropic.
- **It relies on private parts of the ChatGPT app.** OpenAI doesn't offer them as a public interface, so an
  update can break `ucu` at any time.
- **OpenAI's terms still apply to you.** `ucu` runs the engine outside Codex and answers its approval prompt
  for you. Read [OpenAI's Terms of Use](https://openai.com/policies/row-terms-of-use/) and decide whether
  that fits your account. You use it at your own risk.
- **Agents get real access.** Anything an app can do, an agent can do through it. Deny the apps you want to
  keep them out of.

## Requirements

- macOS, with the Xcode Command Line Tools (`xcode-select --install`)
- Python 3.9 or newer
- [Claude Code](https://claude.com/claude-code), with the `claude` command on your `PATH`
- The ChatGPT desktop app, with Computer Use set up in Codex. Run one Computer Use task there first, so
  macOS grants its permissions.

## Install

```bash
git clone https://github.com/betoxf/universal-computer-use.git
cd universal-computer-use
./ucu install
./ucu doctor
```

`ucu` runs from this folder, so keep it. Start a new Claude Code session to pick it up; open sessions need a
restart. If `doctor` reports a problem, it says what to do next. Picking app windows needs Accessibility
permission for the app that runs Claude Code, such as Terminal: **System Settings > Privacy & Security >
Accessibility**.

`./ucu install` backs up what it changes to `~/Library/Application Support/ucu/backups/<time>/`, then:

- builds `~/.local/bin/ucu-window`
- writes the approval policy, unless you already have one
- registers the `ucu` server in `~/.claude.json`
- adds a `Stop` hook to `~/.claude/settings.json`, so `ucu` knows when Claude's turn ends
- registers `ucu` in `~/.config/opencode/opencode.json`, if opencode is set up

If `ucu` doesn't start, install changes nothing. To run the server with a particular Python, use
`./ucu install --python /path/to/python3`.

To make Claude Code prefer `ucu` over its built-in computer use, add this to your `~/.claude/CLAUDE.md`:

```markdown
To operate native Mac apps, use the `ucu` MCP server instead of the built-in computer-use tools.
```

## Choosing which apps agents can use

Agents can use every app except the ones you deny. A new install denies password managers, Keychain Access
and System Settings.

```bash
./ucu deny "Mail"      # block an app
./ucu allow "Mail"     # unblock it
./ucu denied           # list the blocked apps
```

Changes apply at the next prompt, with no restart. Names match regardless of case, and a bundle id such as
`com.apple.mail` works too. The list is in `~/Library/Application Support/ucu/policy.json`:

```json
{
  "deny": ["1Password", "Keychain Access", "System Settings"]
}
```

If that file is missing or broken, every app is asked in Claude instead, so a denied app can't slip through.

Each decision goes to `~/Library/Logs/ucu/approve.log`, with the client and folder that caused it:

```
2026-10-31 14:02:11 claude-code:my-project allowed Google Chrome
2026-10-31 14:02:40 opencode:website denied Mail
```

## Tools

- `js`, `js_reset`, `js_add_node_module_dir`: the engine's own tools.
- `list_windows {app}`: an app's windows, which one is the main window, and whether each is minimized or
  full screen. `cua.getApp(app)` always acts on the main window.
- `focus_window {app, title, unfullscreen?, activate?}`: makes the window whose title contains `title` the
  main window, so the next `cua.getApp(app)` acts on it.

In a `js` call, wait for a window to react instead of sleeping:

```js
const { waitForChange } = await import("<this folder>/js/wait.mjs");
const r = await waitForChange(app, () => app.click(8), { timeoutMs: 20000 }); // { changed, settled, ms, changedBlocks }
```

The server sends the usage rules in its MCP `instructions`, so clients get them without their own config.

## Other MCP clients

Any client that speaks MCP over stdio can run the server directly:

```json
{
  "command": "python3",
  "args": ["-I", "/path/to/universal-computer-use/scripts/ucu-proxy.py"]
}
```

Without the `Stop` hook, a turn ends after 2 minutes without a call.

## Update

```bash
git pull
./ucu install
```

Then start a new session.

## Uninstall

```bash
./ucu uninstall
```

This removes the server, hook and `ucu-window`. Your policy, logs and backups stay in
`~/Library/Application Support/ucu/` and `~/Library/Logs/ucu/`. Delete those and this folder to remove
everything.

## How it works

| Path | What it does |
| --- | --- |
| `ucu` | The `install`, `uninstall`, `doctor`, `deny`, `allow` and `denied` commands. |
| `scripts/ucu-proxy.py` | The MCP server: a stdio proxy that runs the engine as the newest usable Codex plugin defines it, answers app approvals from the policy, adds the window tools and usage rules, ends turns, stops and restarts the engine when idle, and leaves out repeated documentation. |
| `native/ucu-window.swift` | `ucu-window list/focus`, behind the `list_windows` and `focus_window` tools. |
| `js/wait.mjs` | `waitForChange()`, which waits for a window to change and settle. |

## Tests

```bash
python3 -m unittest discover -s tests
```

These run the real proxy and installer against a fake engine in a temporary `HOME`, with fake `claude` and
`swiftc`. `python3 -I tests/smoke_live.py` starts the proxy against your installed Codex plugin and takes one
screenshot of Calculator instead.

## Credits and trademarks

This repo contains no OpenAI code. The engine stays in your own ChatGPT install, under OpenAI's terms.

The approval log's agent names, the warning before repeating a call after a crash, and sending usage rules
from the server were inspired by [agent-desktop](https://github.com/vercel-labs/agent-desktop) from Vercel
Labs (Apache-2.0). No code was copied. If you need an open-source engine or Windows and Linux support, take a
look at it.

OpenAI, ChatGPT and Codex are trademarks of OpenAI. Claude is a trademark of Anthropic. They are named here
only to say what this project works with.

## License

[Apache-2.0](LICENSE). Copyright 2026 Humberto Prado.
