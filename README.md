<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/ucu-logo-dark.svg">
    <img src="assets/brand/ucu-logo-light.svg" alt="UCU: Universal Computer Use" width="220">
  </picture>

  <h3>Universal Computer Use</h3>
  <p><strong>Let your AI agents use your Mac's apps in the background, without touching your mouse or getting in your way.</strong></p>
  <p>Fast, light on tokens, and ready for Claude Code, opencode and any MCP client. An unofficial bridge to the Computer Use engine in the ChatGPT desktop app.</p>

  <p>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-2563EB" alt="Apache-2.0 license"></a>
    <img src="https://img.shields.io/badge/macOS-only-111827" alt="macOS only">
    <img src="https://img.shields.io/badge/Python-3.9%2B-3776AB" alt="Python 3.9 or newer">
    <img src="https://img.shields.io/badge/MCP-server-111827" alt="MCP server">
    <img src="https://img.shields.io/badge/status-unofficial-B45309" alt="Unofficial project">
  </p>

  <p>
    <a href="#why-ucu">Why UCU</a> ·
    <a href="#how-it-compares">How it compares</a> ·
    <a href="#install">Install</a> ·
    <a href="#choosing-which-apps-agents-can-use">Choosing apps</a> ·
    <a href="#tools">Tools</a> ·
    <a href="#how-it-works">How it works</a> ·
    <a href="#before-you-use-it">Before you use it</a>
  </p>
</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/benchmarks/speed-actions-dark.svg">
    <img src="assets/benchmarks/speed-actions-light.svg" alt="Bar chart of single actions. UCU reads a small window in 48 ms, clicks in 26 ms and takes a screenshot in 44 ms, against 103 ms, 48 ms and 288 ms for agent-desktop." width="860">
  </picture>
</p>

## Why UCU

| Capability | What it gives you |
| --- | --- |
| Works in the background | Agents click, type and read other apps without moving your pointer or taking focus. |
| Stays out of your way | A closed app opens hidden, so nothing appears on your screen, and if an app jumps to the front during an agent's action, your app is put back. |
| Sees every window | Agents are told when an app opens a new window, a sheet or a system dialog, with its text and buttons, and `list_windows` lists every open window. |
| Reaches apps without an accessibility tree | Agents can click by screen position in a background window. Some remote-desktop and canvas apps ignore background input. |
| Light on tokens | A task costs about a quarter of the tokens of agent-desktop, and the model gets compact text and diffs. |
| You choose the apps | Every app is approved except the ones you deny, with one command. |
| Shows who did what | Every approval is logged with the agent and folder that caused it. |
| Light when idle | It stops the engine between uses: 19 MB instead of 363 MB. |
| Picks the right window | `focus_window` chooses which window of an app to act on, without moving it. |
| Hears errors | When an app plays the macOS alert sound, the agent is told, at no cost in speed. The engine alone reports success. |
| Stays up to date | A Codex update needs nothing from you: UCU finds the newest engine each time it starts it. |

## How it compares

UCU runs OpenAI's Computer Use engine, so its speed matches the engine on its own. The gap between those two bars
is noise, not a speedup. What UCU adds is everything around the engine: it works
with your agents, stops the engine when idle, shortens what the model has to read, and adds the deny list, the log,
hidden launches, the window tools and the notes about error sounds and new windows.

[agent-desktop](https://github.com/vercel-labs/agent-desktop) from Vercel Labs is a separate, open-source tool
with its own engine. These are the numbers for all three on the same Mac and the same tasks:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/benchmarks/speed-jobs-dark.svg">
    <img src="assets/benchmarks/speed-jobs-light.svg" alt="Bar chart of longer jobs. UCU finishes a task in 1.0 s against 462 ms for agent-desktop, and reads a large window in 1.5 s against 3.0 s, or 164 ms for agent-desktop's outline. agent-desktop starts faster, 256 ms against 774 ms." width="860">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/benchmarks/tokens-dark.svg">
    <img src="assets/benchmarks/tokens-light.svg" alt="Bar chart of tokens. A task takes 518 tokens with UCU and 2,110 with agent-desktop. Reading a small window takes 390 against 1,100, and a large window 1,651 against 2,542, or 1,112 for agent-desktop's outline." width="860">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/benchmarks/overhead-dark.svg">
    <img src="assets/benchmarks/overhead-light.svg" alt="Bar chart of setup and idle memory. Setting up a session takes 4,091 tokens with UCU and 2,882 with agent-desktop. Idle memory is 19 MB for UCU, 363 MB for the Codex engine alone and 15 MB for agent-desktop." width="860">
  </picture>
</p>

**Where UCU wins**

- Reads a small window 2.2 times faster, clicks 1.9 times faster and takes screenshots 6.5 times faster than agent-desktop.
- Uses 4 times fewer tokens on the task, with 2 model round trips, the same as agent-desktop with `batch`, and pulls
  ahead on total tokens from the first task.
- Can click by position in a background window. agent-desktop needs `--headed` for that, which moves your real
  pointer and takes focus.
- Tells the agent when an app plays its error sound or opens another window.
- Opens closed apps hidden. Agents can read them, take screenshots and click their elements without showing them.
- Has a per-app deny list and an approval log, and works as an MCP server.

**Where agent-desktop wins**

- Finishes the task faster: 462 ms against 1.0 s. A single click is faster with UCU, but the engine waits about 450 ms
  before it reads a window after an action.
- Starts three times as fast: 256 ms against 774 ms.
- Costs less to set up: 2,882 tokens against 4,091.
- Gives a quick outline of a large window in 164 ms, then lets the agent drill in. UCU reads the whole window.
- Is fully open source, runs on Windows and Linux too, and uses slightly less memory when idle (15 MB against 19 MB).
- Reports if each action was delivered and if a retry is safe, and rejects stale element references.

| Test (median) | UCU | Codex engine alone | agent-desktop |
| --- | ---: | ---: | ---: |
| Read a small window | 48 ms | 77 ms | 103 ms |
| Click a button | 26 ms | 30 ms | 48 ms |
| Take a screenshot | 44 ms | 49 ms | 288 ms |
| Finish a task | 1.0 s | 1.0 s | 462 ms |
| Read a large window | 1.5 s | 1.6 s | 3.0 s (outline only: 164 ms) |
| Start from nothing | 774 ms | 622 ms | 256 ms |
| Tokens for the task | 518 | 552 | 2,110 |
| Tokens to read a small window | 390 | 390 | 1,100 |
| Tokens to read a large window | 1,651 | 1,651 | 2,542 (outline only: 1,112) |
| Tokens to set up a session | 4,091 | 6,366 | 2,882 |
| Memory while idle | 19 MB | 363 MB | 15 MB |

<details>
<summary>How this was measured</summary>

Run on one Apple M3 Max with macOS 27.2, the Codex plugin 26.1027.30824 and agent-desktop 1.0.2, so your numbers
will differ. These are this project's own benchmarks, and the script is in the repo so you can check them:

```bash
python3 -I benchmarks/run.py --agent-desktop /path/to/agent-desktop
python3 -I benchmarks/chart.py
```

- The small window is Calculator and the large one is Font Book. The task is pressing `12 + 34 =` and reading the
  answer, starting from a cleared display and seeing the buttons.
- The tools take turns sample by sample, for 3 rounds. Each number is a median of up to 30 samples. Reads of large
  windows varied the most between runs.
- The clock covers the tool only, not the model's thinking time. agent-desktop runs through its CLI, as an agent
  would use it, with `-i --compact` and `batch`, the options its docs recommend to save tokens.
- Tokens are estimated as characters / 4, and count what the model reads and writes. Screenshots aren't counted.
- Setup counts tool definitions, the usage rules and the first-use docs for UCU and the engine, and the two
  `skills get` guides for agent-desktop. Tool definitions go with every request, usually from a cache.
- UCU's setup is smaller because it leaves the browser part out of the docs and the tool list until a call needs it,
  drops two tools agents don't use, and replaces the engine's confirmations policy with a short summary. The summary
  only applies to the policy version it was written from. If an update changes that policy, the full text goes through.
  It also shortens the sentences the engine repeats on each state, which is the small saving on the task.
- Idle memory leaves out the Computer Use service itself, which UCU and the engine share. UCU stops the
  engine 2 minutes after a turn ends.

</details>

## Before you use it

- **This is an unofficial project.** It is not made by, affiliated with, or endorsed by OpenAI or Anthropic.
- **It relies on private parts of the ChatGPT app.** OpenAI doesn't offer them as a public interface, so an
  update can break UCU at any time.
- **OpenAI's terms still apply to you.** UCU runs the engine outside Codex and answers its approval prompt
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

UCU runs from this folder, so keep it. Start a new Claude Code session to pick it up; open sessions need a
restart. If `doctor` reports a problem, it says what to do next. Picking app windows needs Accessibility
permission for the app that runs Claude Code, such as Terminal: **System Settings > Privacy & Security >
Accessibility**.

`./ucu install` backs up what it changes to `~/Library/Application Support/ucu/backups/<time>/`, then:

- builds `~/.local/bin/ucu-window`
- writes the approval policy, unless you already have one
- registers the `ucu` server in `~/.claude.json`
- adds a `Stop` hook to `~/.claude/settings.json`, so UCU knows when Claude's turn ends
- registers `ucu` in `~/.config/opencode/opencode.json`, if opencode is set up

If UCU doesn't start, install changes nothing. To run the server with a particular Python, use
`./ucu install --python /path/to/python3`.

To make Claude Code prefer UCU over its built-in computer use, add this to your `~/.claude/CLAUDE.md`:

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

- `js`, `js_reset`: the engine's own tools.
- `list_windows {app?}`: the windows of an app, or of every app without `app`, which one is the main window, and
  whether each is a dialog, minimized or full screen. `cua.getApp(app)` always acts on the main window.
- `focus_window {app, title, unfullscreen?, activate?}`: makes the window whose title contains `title` the
  main window, so the next `cua.getApp(app)` acts on it. The window stays where it is. With `activate: true`, the app
  also comes to the front, for when you should see it.

In a `js` call, wait for a window to react instead of sleeping:

```js
const { waitForChange } = await import("<this folder>/js/wait.mjs");
const r = await waitForChange(app, () => app.click(8), { timeoutMs: 20000 }); // { changed, settled, ms, changedBlocks }
```

When an app rejects an input it plays the macOS alert sound, which a person hears but an agent can't. UCU watches
the system sound server's log and adds a note to a `js` result:

```
[ucu: Calculator played an alert sound during your last actions, which usually means it rejected an input. Check the app before going on.]
```

Nothing waits for a sound, so this adds no time to a call. The note comes with the same result if a read follows the
action in that call, and with the next result if not. It needs no permission, hears no audio, and only reports apps
that chat is driving.

New windows work the same way. While a call runs, and for a moment after, UCU compares the windows of the apps that
chat drives and looks for system dialogs such as password prompts:

```
[ucu: Safari opened a dialog titled "Sign in". Its text: "Enter your password". Buttons: "Cancel", "OK". To act on it, call focus_window with its title, then cua.getApp.]
```

The server sends the usage rules in its MCP `instructions`, so clients get them without their own config.

### Staying out of your way

When an agent calls `cua.getApp` on a closed app, UCU opens it hidden first. Its Dock icon shows it is running, and
nothing appears on screen unless you click that icon or the agent calls `focus_window` with `activate: true`. Apps
that show themselves anyway, such as Blender, are hidden as soon as their window appears, behind your front app. A
denied app stays closed.

The agent reads a hidden app, takes screenshots of it and clicks its elements as usual. Two things need a window on
screen: input by coordinates, and a few actions that an app refuses while hidden, such as opening its settings. For
those, UCU shows the app behind your windows, without taking focus. Agents that open an app with the `open` command
skip all of this, so the usage rules tell them not to.

If an app comes to the front during an agent's call or just after it, and it is an app that chat drives or one that
just started, UCU puts your app back and tells the agent. If you pressed a key or clicked just before, it does nothing,
because you may have switched apps yourself.

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
| `scripts/ucu-proxy.py` | The MCP server: a stdio proxy that runs the engine as the newest usable Codex plugin defines it, answers app approvals from the policy, adds the window tools and usage rules, ends turns, stops and restarts the engine when idle, and shortens what the model reads. |
| `native/ucu-window.swift` | `ucu-window list/focus`, behind the `list_windows` and `focus_window` tools, and `ucu-window watch`, which opens apps hidden and reports new windows while the engine runs. |
| `js/wait.mjs` | `waitForChange()`, which waits for a window to change and settle. |

## Tests

```bash
python3 -m unittest discover -s tests
```

These run the real proxy and installer against a fake engine in a temporary `HOME`, with fake `claude` and
`swiftc`. `python3 -I tests/smoke_live.py` starts the proxy against your installed Codex plugin and takes one
screenshot of Calculator instead. `benchmarks/` holds the benchmark behind the charts on this page.

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
