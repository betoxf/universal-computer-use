#!/bin/bash
# Install Universal Computer Use (UCU) on a Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/betoxf/universal-computer-use/main/ucu/install.sh | bash
#
# It checks for macOS, the Xcode Command Line Tools, Python 3.9 or newer, git, and Claude Code, Codex or opencode. It installs
# Rust through rustup if it is missing, after asking. It clones UCU to ~/.ucu, or brings an existing clone there up to
# date, then runs `ucu install` and `ucu doctor` from it. Running it again is safe. It leaves a clone with local
# changes as it is, and if UCU is already installed from another folder, it says so and changes nothing.
#
#   --clients LIST       the agents to set UCU up for: all (every one found, the default) or a list such as claude,codex
#   --rule global|none   global: add a rule to those agents' global instructions to use UCU instead of built-in computer
#                        use; none: take it out. Unset, it stays as chosen before (none at first)
#   --yes                install Rust without asking (also UCU_YES=1); needed when there is no terminal to ask in
#   --uninstall          run `ucu uninstall` from the installed clone, which stays where it is
#   --help               show this help
#
#   UCU_DIR      where to clone UCU (default: ~/.ucu)
#   UCU_REPO     the repository to clone (default: https://github.com/betoxf/universal-computer-use.git)
#   UCU_BRANCH   the branch to clone (default: main)
set -euo pipefail

UCU_DIR="${UCU_DIR:-$HOME/.ucu}"
UCU_REPO="${UCU_REPO:-https://github.com/betoxf/universal-computer-use.git}"
UCU_BRANCH="${UCU_BRANCH:-main}"
UCU_YES="${UCU_YES:-}"
CLIENTS=""
RULE=""
ONE_LINER="curl -fsSL https://raw.githubusercontent.com/betoxf/universal-computer-use/main/ucu/install.sh | bash"
PYTHON=""

say() { printf '%s %s\n' "$1" "$2"; }
# The first line of a failure, then any more lines that say what to do about it.
fail() {
  local line
  printf '✗ %s\n' "$1" >&2
  shift
  for line in "$@"; do
    printf '  %s\n' "$line" >&2
  done
  exit 1
}

usage() {
  cat <<EOF
Install Universal Computer Use (UCU), the MCP server that lets AI agents use your Mac's apps in the background.

Usage: $ONE_LINER
       $ONE_LINER -s -- [--clients LIST] [--rule global|none] [--yes]
       $ONE_LINER -s -- --uninstall | --help

  --clients LIST       the agents to set UCU up for: all (every one found, the default) or a list such as claude,codex
  --rule global|none   global: add a rule to those agents' global instructions to use UCU instead of built-in computer
                       use; none: take it out. Unset, it stays as chosen before (none at first)
  --yes                install Rust without asking (also UCU_YES=1); needed when there is no terminal to ask in
  --uninstall          run \`ucu uninstall\` from the installed clone, which stays where it is
  --help               show this help

  UCU_DIR      where to clone UCU (default: ~/.ucu)
  UCU_REPO     the repository to clone (default: https://github.com/betoxf/universal-computer-use.git)
  UCU_BRANCH   the branch to clone (default: main)
EOF
}

# Find a command on PATH, or where Claude Code's and rustup's installers put it before a new shell has it on PATH.
find_tool() {
  local dir
  if command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
    return 0
  fi
  for dir in "$HOME/.local/bin" "${CARGO_HOME:-$HOME/.cargo}/bin"; do
    if [ -x "$dir/$1" ]; then
      printf '%s\n' "$dir/$1"
      return 0
    fi
  done
  return 1
}

# Ask a yes-or-no question. Returns 0 for yes (or --yes), 1 for no, 2 when there is no terminal to ask in.
# Under `curl | bash` the script is stdin, so the answer is read from the terminal itself.
ask() {
  local answer=""
  if [ "$UCU_YES" = 1 ]; then
    return 0
  fi
  if ! (: </dev/tty) 2>/dev/null; then
    return 2
  fi
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y | Y | yes | Yes | YES) return 0 ;;
  esac
  return 1
}

check_mac() {
  if [ "$(uname -s)" != Darwin ]; then
    fail "UCU runs on macOS only"
  fi
  # Before anything calls git or python3: without the Command Line Tools, /usr/bin's copies open an install dialog.
  if ! xcode-select -p >/dev/null 2>&1; then
    fail "the Xcode Command Line Tools are missing." \
      "Run \`xcode-select --install\`, wait for it to finish, then run this again."
  fi
  say "✓" "macOS with the Xcode Command Line Tools"
}

check_python() {
  if ! PYTHON="$(command -v python3)"; then
    fail "python3 was not found. Install Python 3.9 or newer (https://www.python.org/downloads/), then run this again."
  fi
  if ! "$PYTHON" -I -c 'import sys; sys.exit(sys.version_info < (3, 9))' </dev/null >/dev/null 2>&1; then
    fail "$PYTHON is older than Python 3.9." \
      "Install a newer one (https://www.python.org/downloads/), then run this again."
  fi
  say "✓" "$("$PYTHON" -I -c 'import platform; print("Python", platform.python_version())' </dev/null) at $PYTHON"
}

# Print the clone that the installed ucu server runs from, as Claude Code's, Codex's or opencode's config names it, if
# any.
registered_clone() {
  "$PYTHON" -I - "$HOME" "$(find_tool codex || true)" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

home, codex = Path(sys.argv[1]), sys.argv[2]


def proxies():
    for config, keys in ((".claude.json", ("mcpServers", "ucu", "args")),
                         (".config/opencode/opencode.json", ("mcp", "ucu", "command"))):
        try:
            value = json.loads((home / config).read_text())
            for key in keys:
                value = value[key]
            yield Path(str(value[-1]))
        except (OSError, ValueError, LookupError, TypeError):
            pass
    if codex:  # Codex keeps its servers in TOML, which this Python may not read, so its CLI is asked
        try:
            path = os.pathsep.join([os.path.dirname(codex), os.environ.get("PATH", "")])
            found = subprocess.run([codex, "mcp", "get", "ucu", "--json"], capture_output=True, text=True, timeout=60,
                                   stdin=subprocess.DEVNULL, env={**os.environ, "PATH": path})
            yield Path(str(json.loads(found.stdout)["transport"]["args"][-1]))
        except (OSError, ValueError, LookupError, TypeError, subprocess.TimeoutExpired):
            pass


for proxy in proxies():
    if proxy.name == "ucu-proxy.py" and proxy.is_file():
        print(proxy.resolve().parents[2])
        break
PY
}

is_clone() {
  [ -f "$1/ucu/ucu" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# The folder, with symlinks resolved, or the path as given when it doesn't exist.
real_dir() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

check_agent() {
  local found=""
  if find_tool claude >/dev/null; then
    say "✓" "Claude Code at $(find_tool claude)"
    found=1
  fi
  if find_tool codex >/dev/null; then
    say "✓" "Codex at $(find_tool codex)"
    found=1
  fi
  if find_tool opencode >/dev/null || [ -f "$HOME/.config/opencode/opencode.json" ]; then
    say "✓" "opencode"
    found=1
  fi
  if [ -z "$found" ]; then
    fail "no agent was found: neither Claude Code (the claude command), Codex (the codex command) nor opencode." \
      "Install one of them, then run this again."
  fi
}

check_rust() {
  local status=0
  if find_tool cargo >/dev/null; then
    say "✓" "Rust, with cargo at $(find_tool cargo)"
    return 0
  fi
  if find_tool rustup >/dev/null; then
    say "✓" "Rust, through rustup at $(find_tool rustup); if it has no toolchain yet, the build downloads one"
    return 0
  fi
  echo "UCU builds its engine from source with Rust, which isn't installed. rustup (https://rustup.rs) can install it"
  echo "to ~/.rustup and ~/.cargo, and adds ~/.cargo/bin to your shell's PATH."
  ask "Install Rust with rustup now?" || status=$?
  if [ "$status" = 2 ]; then
    fail "Rust is missing, and there is no terminal to ask in." \
      "Install Rust from https://rustup.rs and run this again, or let this script install it:" \
      "$ONE_LINER -s -- --yes"
  elif [ "$status" != 0 ]; then
    fail "UCU needs Rust. Install it from https://rustup.rs, then run this again."
  fi
  if ! command -v curl >/dev/null 2>&1; then
    fail "curl was not found, so rustup can't be downloaded"
  fi
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
  export PATH
  if ! find_tool cargo >/dev/null; then
    fail "rustup finished, but cargo was not found in ${CARGO_HOME:-$HOME/.cargo}/bin"
  fi
  say "✓" "installed Rust"
}

# Clone UCU to UCU_DIR, or bring the clone there up to date when it has nothing of its own.
get_clone() {
  if is_clone "$UCU_DIR"; then
    say "✓" "UCU is already cloned at $UCU_DIR"
    if ! "$PYTHON" -I "$UCU_DIR/ucu/ucu" update </dev/null; then
      say "!" "installing the clone at $UCU_DIR as it is"
    fi
    return 0
  fi
  if [ -e "$UCU_DIR" ] && [ -n "$(ls -A "$UCU_DIR" 2>/dev/null)" ]; then
    fail "$UCU_DIR exists and isn't a clone of UCU. Move it, or choose another folder with UCU_DIR=..."
  fi
  mkdir -p "$(dirname "$UCU_DIR")"
  say "→" "cloning $UCU_REPO ($UCU_BRANCH) to $UCU_DIR"
  git clone --quiet --branch "$UCU_BRANCH" "$UCU_REPO" "$UCU_DIR" </dev/null
  say "✓" "cloned UCU to $UCU_DIR"
}

next_steps() {
  local ucu="$UCU_DIR/ucu/ucu"
  cat <<EOF

Next steps:
  1. Start a new session of your agent. Sessions that are open now need a restart to get ucu.
  2. In System Settings > Privacy & Security, give the app that runs your agent, such as Terminal or the Claude or
     Codex app, Accessibility permission, and Screen Recording for screenshots. Then check again with: "$ucu" doctor
  3. Agents can use every app you don't deny. Block one with: "$ucu" deny "Mail"
  4. To tell agents to use ucu in one project only: "$ucu" rule add /path/to/project

UCU runs from $UCU_DIR and updates itself there, so keep that folder.
To remove UCU: "$ucu" uninstall
EOF
}

install_ucu() {
  local existing="" status=0
  check_mac
  check_python
  if ! command -v git >/dev/null 2>&1; then
    fail "git was not found. It comes with the Xcode Command Line Tools: run \`xcode-select --install\`."
  fi
  existing="$(registered_clone)"
  if [ -n "$existing" ] && [ "$existing" != "$(real_dir "$UCU_DIR")" ]; then
    say "✓" "UCU is already installed from $existing, so nothing was changed"
    echo "To update it:  cd \"$existing/ucu\" && ./ucu update && ./ucu install"
    echo "To move it to $UCU_DIR, run \"$existing/ucu/ucu\" uninstall first, then this again."
    return 0
  fi
  check_agent
  check_rust
  get_clone
  local options=(--python "$PYTHON")
  if [ -n "$CLIENTS" ]; then
    options+=(--clients "$CLIENTS")
  fi
  if [ -n "$RULE" ]; then
    options+=(--rule "$RULE")
  fi
  "$PYTHON" -I "$UCU_DIR/ucu/ucu" install "${options[@]}" </dev/null
  echo
  "$PYTHON" -I "$UCU_DIR/ucu/ucu" doctor </dev/null || status=$?
  if [ "$status" != 0 ]; then
    echo
    say "!" "doctor found something to fix, shown above. On a new Mac it is usually the permissions in step 2 below."
  fi
  next_steps
}

uninstall_ucu() {
  local clone=""
  check_mac
  check_python
  clone="$(registered_clone)"
  if [ -z "$clone" ] && is_clone "$UCU_DIR"; then
    clone="$UCU_DIR"
  fi
  if [ -z "$clone" ]; then
    fail "UCU is not installed: no agent's config runs it, and $UCU_DIR isn't a clone of it"
  fi
  "$PYTHON" -I "$clone/ucu/ucu" uninstall </dev/null
  echo "The clone at $clone stays. Delete it if you no longer need it: rm -rf \"$clone\""
}

main() {
  local action=install
  while [ $# -gt 0 ]; do
    case "$1" in
      -y | --yes) UCU_YES=1 ;;
      --clients | --rule)
        if [ $# -lt 2 ]; then
          usage >&2
          printf '✗ %s needs a value\n' "$1" >&2
          return 2
        fi
        if [ "$1" = --clients ]; then CLIENTS="$2"; else RULE="$2"; fi
        shift
        ;;
      --clients=*) CLIENTS="${1#--clients=}" ;;
      --rule=*) RULE="${1#--rule=}" ;;
      --uninstall) action=uninstall ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        usage >&2
        printf '✗ unknown option: %s\n' "$1" >&2
        return 2
        ;;
    esac
    shift
  done
  if [ "$action" = uninstall ]; then
    uninstall_ucu
  else
    install_ucu
  fi
}

main "$@"
