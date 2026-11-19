#!/usr/bin/env bash
# Build a self-contained CLI bundle: the Textual app frozen with PyInstaller plus
# the Rust engine_daemon next to it, as inbox2-cli-<os>-<arch>.tar.gz. Used by
# .github/workflows/cli-release.yml and runnable locally:
#
#   ui/cli/tools/build.sh                 # → ui/cli/dist/inbox2-cli-darwin-arm64.tar.gz
#   ui/cli/tools/build.sh --skip-daemon   # reuse target/release/engine_daemon
#
# The version is bin/version's scheme (MAJOR.MINOR from pyproject, PATCH = commit
# count), written into pyproject before the wheel is built so `inbox2 --version`
# and the wheel agree. No Windows: the engine bus is a Unix socket.
set -euo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLI="$ROOT/ui/cli"
TAURI="$ROOT/ui/desktop/src-tauri"
PY="${PYTHON:-$CLI/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

os=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin | linux
arch=$(uname -m)                             # arm64 | x86_64 | aarch64
base=$(sed -n 's/^version = "\([0-9]*\.[0-9]*\)\..*/\1/p' "$CLI/pyproject.toml" | head -1)
version="$base.$("$ROOT/bin/version" | cut -d. -f3)" # the desktop patch number, history offset included
echo "inbox2-cli $version ($os-$arch)"

if [ "${1:-}" != "--skip-daemon" ]; then
  (cd "$TAURI" && cargo build --release --bin engine_daemon)
fi
# The desktop crates share a workspace target dir (ui/desktop/target) — ask cargo.
target_dir=$(cd "$TAURI" && cargo metadata --format-version 1 --no-deps | "$PY" -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])')
daemon="$target_dir/release/engine_daemon"
[ -x "$daemon" ] || { echo "engine_daemon not built at $daemon" >&2; exit 1; }

cd "$CLI"
# Stamp the version (the checkout is disposable in CI; locally it's restored below).
cp pyproject.toml /tmp/inbox2-cli-pyproject.bak
trap 'cp /tmp/inbox2-cli-pyproject.bak "$CLI/pyproject.toml"' EXIT
sed -i.tmp "s/^version = \".*\"/version = \"$version\"/" pyproject.toml && rm -f pyproject.toml.tmp

# A uv-made venv has no pip; bootstrap it.
"$PY" -m pip --version >/dev/null 2>&1 || "$PY" -m ensurepip --upgrade >/dev/null
"$PY" -m pip install -q --upgrade pip pyinstaller build
"$PY" -m pip install -q .
rm -rf build dist
"$PY" -m build --wheel --outdir dist >/dev/null
"$PY" -m PyInstaller --noconfirm --clean --onedir --name inbox2 \
  --collect-all textual --collect-all rich --collect-all rich_pixels \
  --copy-metadata inbox2-cli \
  --add-data "inbox2_cli/assets:inbox2_cli/assets" \
  tools/entry.py >/dev/null
cp "$daemon" dist/inbox2/engine_daemon
chmod +x dist/inbox2/inbox2 dist/inbox2/engine_daemon
if [ "$os" = darwin ]; then
  # Ad-hoc signatures: arm64 macOS refuses to run unsigned code at all.
  codesign --force --deep -s - dist/inbox2/engine_daemon dist/inbox2/inbox2 2>/dev/null || true
fi

dist/inbox2/inbox2 --version
tar -C dist -czf "dist/inbox2-cli-$os-$arch.tar.gz" inbox2
echo "$version" > dist/VERSION
ls -la dist/*.tar.gz dist/*.whl
