#!/usr/bin/env bash
# Build ucu's MCPB bundle, ucu/dist/ucu.mcpb, for the MCP Registry and the GitHub Release it points to.
#
#   ucu/mcpb/pack-mcpb.sh [--update-server-json]
#
# It builds the engine (agent-desktop, `cargo build --release -p agent-desktop`, as `ucu install` does) and
# ucu-window (swiftc), stages them with launch.py, the `ucu` command, scripts/ucu-proxy.py and native/browser.js
# under server/, packs the stage with the official mcpb CLI, and prints the file's SHA-256. With
# --update-server-json it also writes that hash into fileSha256 in the repository's server.json.
#
# Needs an Apple silicon Mac with Rust (rustup), the Xcode Command Line Tools, Python 3 and Node (for npx).
# The build is not reproducible: every run gives a new hash, so the file uploaded to the Release must be the one
# whose hash is in server.json.
set -euo pipefail

MCPB_CLI="@anthropic-ai/mcpb@2.1.2"
MACOS_MIN="11.0"  # the oldest macOS on Apple silicon; the engine sets its own (crates/macos/build.rs)

HERE="$(cd "$(dirname "$0")" && pwd)"
UCU="$(dirname "$HERE")"
REPO="$(dirname "$UCU")"
DIST="$UCU/dist"
STAGE="$DIST/mcpb-stage"
OUT="$DIST/ucu.mcpb"

update_server_json=0
case "${1:-}" in
  "") ;;
  --update-server-json) update_server_json=1 ;;
  *) echo "usage: $0 [--update-server-json]" >&2; exit 2 ;;
esac

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo "✗ build this on an Apple silicon Mac" >&2; exit 1; }

version="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$HERE/manifest.json")"
echo "• packing ucu $version"

cargo="$(command -v cargo || (cd "$REPO" && rustup which cargo))"  # a Homebrew rustup puts no cargo on PATH
export PATH="$(dirname "$cargo"):$PATH"

echo "• building the engine (agent-desktop)"
"$cargo" build --release -p agent-desktop --manifest-path "$REPO/Cargo.toml"
engine="${CARGO_TARGET_DIR:-$REPO/target}/release/agent-desktop"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/server/bin" "$STAGE/server/ucu/scripts" "$STAGE/server/ucu/native"

echo "• building ucu-window"
swiftc -O -target "arm64-apple-macos$MACOS_MIN" "$UCU/native/ucu-window.swift" -o "$STAGE/server/bin/ucu-window"

cp "$engine" "$STAGE/server/bin/ucu-engine"
cp "$HERE/manifest.json" "$STAGE/manifest.json"
cp "$REPO/LICENSE" "$STAGE/LICENSE"
cp "$HERE/launch.py" "$STAGE/server/launch.py"
cp "$UCU/ucu" "$UCU/LICENSE" "$STAGE/server/ucu/"
cp "$UCU/scripts/ucu-proxy.py" "$STAGE/server/ucu/scripts/"
cp "$UCU/native/browser.js" "$STAGE/server/ucu/native/"
chmod 755 "$STAGE/server/bin/ucu-engine" "$STAGE/server/bin/ucu-window"

echo "• validating and packing with $MCPB_CLI"
npx -y "$MCPB_CLI" validate "$STAGE/manifest.json"
npx -y "$MCPB_CLI" pack "$STAGE" "$OUT"

sha="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
if [ "$update_server_json" = 1 ]; then
  python3 -I - "$REPO/server.json" "$version" "$sha" <<'PY'
import json, sys
path, version, sha = sys.argv[1:]
data = json.load(open(path))
assert data["version"] == version, f"server.json is at {data['version']}, the manifest at {version}"
for package in data["packages"]:
    if package["registryType"] == "mcpb":
        package["fileSha256"] = sha
open(path, "w").write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  echo "• wrote the hash into server.json"
fi

echo "✓ $OUT"
echo "  version $version"
echo "  sha256  $sha"
