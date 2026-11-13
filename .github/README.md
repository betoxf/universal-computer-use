<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/betoxf/universal-computer-use/main/ucu/assets/brand/ucu-logo-dark.svg">
    <img src="https://raw.githubusercontent.com/betoxf/universal-computer-use/main/ucu/assets/brand/ucu-logo-light.svg" alt="UCU: Universal Computer Use" width="220">
  </picture>

  <h3>Universal Computer Use</h3>
  <p><strong>Let your AI agents use your Mac's apps in the background, without touching your mouse or getting in your way.</strong></p>
  <p>An MCP server for Claude Code, opencode and any MCP client. Built on <a href="https://github.com/vercel-labs/agent-desktop">agent-desktop</a> from Vercel Labs.</p>

  <p>
    <a href="https://github.com/betoxf/universal-computer-use/blob/main/ucu/LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-2563EB" alt="Apache-2.0 license"></a>
    <img src="https://img.shields.io/badge/macOS-only-111827" alt="macOS only">
    <img src="https://img.shields.io/badge/MCP-server-111827" alt="MCP server">
    <img src="https://img.shields.io/badge/engine-Rust-B7410E" alt="Rust engine">
  </p>

  <p>
    <a href="#why-ucu">Why UCU</a> ·
    <a href="#install">Install</a> ·
    <a href="https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md">Full documentation</a> ·
    <a href="#whats-in-this-repository">What's here</a>
  </p>
</div>

## Why UCU

| Capability | What it gives you |
| --- | --- |
| Works in the background | Agents click, type and read other apps without moving your pointer or taking focus. |
| Stays out of your way | A closed app opens on a private desktop you never see, and apps agents drive can't take your focus. |
| Clicks anything | A click by position presses the element at that point, or sends raw input to the window, even a canvas with no accessibility tree. |
| Shares your browsers | The `safari` and `chrome` tools work in the agent's own window, so you keep your tabs and your keyboard. |
| Runs side by side | Each chat has its own engine and its own cursor color, and is told when another chat is using the same app. |
| Light on tokens and round trips | The model reads short numbered text and only what changed, acts by name, and does many steps in one call. |
| You choose the apps | Every app is approved except the ones you deny, with one command. |

Reading a small window such as Calculator takes about 260 ms and 169 tokens; the
[benchmarks](https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md#how-fast-it-is) have the rest.

## Install

You need macOS with the Xcode Command Line Tools, Rust through [rustup](https://rustup.rs), Python 3.9 or newer, and
[Claude Code](https://claude.com/claude-code) with the `claude` command on your `PATH`.

```bash
git clone https://github.com/betoxf/universal-computer-use.git
cd universal-computer-use/ucu
./ucu install
./ucu doctor
```

UCU runs from that folder and updates itself from it. Start a new Claude Code session to pick it up. The app that runs
Claude Code needs Accessibility permission, and Screen Recording for screenshots.

Before you use it: agents get real access to every app you don't deny. Read
[Before you use it](https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md#before-you-use-it) and
[Choosing which apps agents can use](https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md#choosing-which-apps-agents-can-use).

## What's in this repository

| Path | What it holds |
| --- | --- |
| [`ucu/`](https://github.com/betoxf/universal-computer-use/tree/main/ucu) | UCU: the MCP server, the installer, the window helper, tests and the [full documentation](https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md). |
| Everything else | [agent-desktop](https://github.com/vercel-labs/agent-desktop), the Rust engine UCU drives, with UCU's changes to it. Its own README is [README.md](https://github.com/betoxf/universal-computer-use/blob/main/README.md). |

[FORK.md](https://github.com/betoxf/universal-computer-use/blob/main/FORK.md) explains how this repository stays in sync
with agent-desktop. Versions before the move, which used the Computer Use engine in the ChatGPT desktop app, are kept at
the [`python-final`](https://github.com/betoxf/universal-computer-use/tree/python-final) tag.

## License

UCU: [Apache-2.0](https://github.com/betoxf/universal-computer-use/blob/main/ucu/LICENSE), Copyright 2026 Humberto Prado.
agent-desktop: [Apache-2.0](https://github.com/betoxf/universal-computer-use/blob/main/LICENSE), Vercel Labs. Claude is a
trademark of Anthropic, named here only to say what this project works with.
