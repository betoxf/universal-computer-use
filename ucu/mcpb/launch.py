#!/usr/bin/env python3
"""Start ucu's MCP server from its MCPB bundle.

The bundle keeps this file at server/launch.py, ucu's own files at server/ucu/ (the `ucu` command,
scripts/ucu-proxy.py and native/browser.js), and the prebuilt engine and ucu-window at server/bin/.
A clone set up with `ucu install` runs them from ~/.local/bin and updates itself with git. A bundle
has neither, so this:

* points the server at the bundle's own engine and ucu-window;
* writes the default approval policy if there is none yet, as `ucu install` does, since without a
  policy the server uses no app;
* turns self-update off: a bundle changes only when its client installs a newer one.

pack-mcpb.sh builds the bundle, and tests/test_mcpb.py runs this file from a bundle laid out the same way.
"""
import contextlib
import importlib.machinery
import importlib.util
import sys
from pathlib import Path

SERVER = Path(__file__).resolve().parent
ENGINE = SERVER / "bin/ucu-engine"
WINDOW_HELPER = SERVER / "bin/ucu-window"
COMMAND = SERVER / "ucu/ucu"


def load_command():
    loader = importlib.machinery.SourceFileLoader("ucu_command", str(COMMAND))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def main():
    sys.dont_write_bytecode = True  # keep the installed bundle as it was packed
    command = load_command()
    proxy = command.proxy
    proxy.ENGINE = ENGINE
    proxy.WINDOW_HELPER = WINDOW_HELPER
    proxy.check_for_update = lambda: None
    with contextlib.redirect_stdout(sys.stderr):  # stdout carries the MCP messages
        command.seed_policy()
    proxy.main()


if __name__ == "__main__":
    main()
