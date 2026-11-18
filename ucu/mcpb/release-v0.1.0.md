# UCU 0.1.0

UCU (Universal Computer Use) is a local MCP server that lets AI agents use your Mac's apps in the background, without
moving your pointer or taking your focus. Agents read an app through its accessibility tree and act on it by name;
apps they drive open on a private desktop you never see. It runs on [agent-desktop](https://github.com/vercel-labs/agent-desktop)
from Vercel Labs.

This is UCU's first release, and its first prebuilt artifact: `ucu.mcpb`, an [MCP Bundle](https://github.com/modelcontextprotocol/mcpb)
that installs without Rust or a clone of this repository. It is also the package the
[MCP Registry](https://registry.modelcontextprotocol.io) entry `io.github.betoxf/universal-computer-use` points to.

## Install

- **Claude Desktop, or another client that installs MCP Bundles:** download `ucu.mcpb` and open it, or install it from
  the client's extension settings.
- **Claude Code and opencode:** install from source with `./ucu install`, as in the
  [README](https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md#install). The source install adds
  the Stop hook, the Chrome companion and self-update, which the bundle doesn't have.

Install UCU one way only: both register a server named `ucu`.

## What you need

- An Apple silicon Mac. The bundle's engine and `ucu-window` are arm64 builds for macOS 11 or newer; UCU is tested on
  macOS 27.2.
- Python 3.9 or newer as `python3`. The Xcode Command Line Tools provide one (`xcode-select --install`).
- Accessibility permission for the app that runs your MCP client, and Screen Recording for screenshots, in
  **System Settings > Privacy & Security**.

## What the bundle does differently

- On its first start it writes the approval policy that `ucu install` writes, at
  `~/Library/Application Support/ucu/policy.json`: every app is approved except password managers, Keychain Access and
  System Settings. An existing policy is kept. Change it in that file; the `ucu deny` and `ucu allow` commands come with
  the source install.
- It runs its own engine and `ucu-window` from the bundle, not from `~/.local/bin`.
- It doesn't update itself. Install a newer bundle to update.
- The `chrome` tool works through AppleScript, since the Chrome companion extension isn't set up. Without the Claude
  Code Stop hook, a turn ends after two minutes without a call.

## Before you use it

Agents get real access: anything an app can do, an agent can do through it. The private desktop is a virtual display
made with a private macOS feature, and raw clicks use a macOS function Apple doesn't document. The bundle's binaries
are ad-hoc signed, not signed with a Developer ID or notarized. Read
[Before you use it](https://github.com/betoxf/universal-computer-use/blob/main/ucu/README.md#before-you-use-it).

<!-- maintainer-steps: everything below is for the maintainer, not the release body -->

---

## Maintainer steps

This file is the draft body of the GitHub Release `v0.1.0`; everything above the marker is the release text. Nothing
here has been run yet: there is no Release, no tag and no registry entry.

**The artifact.** `ucu/mcpb/pack-mcpb.sh --update-server-json` built it on 2026-11-19 from commit `563d954c` of `main`
plus this packaging:

| | |
| --- | --- |
| File | `ucu.mcpb` (2,256,465 bytes) |
| Kept at | `~/Projects/Shared-Tools/Universal-Computer-Use/Outputs/mcp-registry/v0.1.0/ucu.mcpb` |
| SHA-256 | `e3643248012bed424e816999f702ea9f7fb07db09a285aec9f381bca6e02b30f` |
| Release URL | `https://github.com/betoxf/universal-computer-use/releases/download/v0.1.0/ucu.mcpb` |

The build isn't reproducible, so upload this exact file. If you pack again, or `ucu/` or the engine change on `main`
before the release, run `ucu/mcpb/pack-mcpb.sh --update-server-json`, commit the new `fileSha256` in `server.json`, and
use the new hash and file in every step below.

**1. Merge the registry PR**, so `main` has `server.json`. Then, from a checkout of `main`:

```bash
ARTIFACT=~/Projects/Shared-Tools/Universal-Computer-Use/Outputs/mcp-registry/v0.1.0/ucu.mcpb
git pull
shasum -a 256 "$ARTIFACT"     # must equal fileSha256 in server.json
grep fileSha256 server.json
```

**2. Create the Release** with tag `v0.1.0` on `main` and the artifact attached; its asset name is its file name, `ucu.mcpb`:

```bash
sed '/^<!-- maintainer-steps/,$d' ucu/mcpb/release-v0.1.0.md > /tmp/ucu-v0.1.0-notes.md
gh release create v0.1.0 "$ARTIFACT" --repo betoxf/universal-computer-use --target main \
  --title "UCU 0.1.0" --notes-file /tmp/ucu-v0.1.0-notes.md
```

**3. Check the uploaded file** is the one `server.json` names:

```bash
curl -sSL https://github.com/betoxf/universal-computer-use/releases/download/v0.1.0/ucu.mcpb | shasum -a 256
```

**4. Publish to the MCP Registry**, from the repository root on `main`. Don't run these until the Release exists with
the exact `.mcpb` whose SHA-256 is in `server.json`.

```bash
mcp-publisher validate
mcp-publisher login github
# then complete https://github.com/login/device as betoxf
mcp-publisher publish
```

**5. Confirm the listing:**

```bash
curl -s "https://registry.modelcontextprotocol.io/v0.1/servers?search=io.github.betoxf/universal-computer-use"
```
