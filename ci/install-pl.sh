#!/bin/sh
# Installs the newest signed pl into $PL_BIN (default ~/.local/bin).
set -eu
R=https://releases.pushleft.dev
KEY=ycJxDG57xxcAbQEHazM+5VANSLxjrj1ZerDOjnGixgs=   # the release key, pinned
BIN=${PL_BIN:-$HOME/.local/bin}
V=${PL_VERSION:-$(curl -fsS "$R/cli/latest")}   # set PL_VERSION to pin
T=$(mktemp -d); cd "$T"
curl -fsSO "$R/cli/$V/SHA256SUMS" -fsSO "$R/cli/$V/SHA256SUMS.sig" -fsSO "$R/cli/$V/pl-linux-amd64"
{ printf '302a300506032b6570032100' | xxd -r -p; echo "$KEY" | base64 -d; } > release.der
base64 -d < SHA256SUMS.sig > SHA256SUMS.bin
openssl pkeyutl -verify -pubin -keyform DER -inkey release.der -rawin -in SHA256SUMS -sigfile SHA256SUMS.bin
sha256sum -c --ignore-missing --strict SHA256SUMS
mkdir -p "$BIN" && install -m 0755 pl-linux-amd64 "$BIN/pl"
[ "$("$BIN/pl" --version)" = "pl $V" ]
