#!/bin/bash
# Builds MenuShelf with SwiftPM and wraps the binary in build/MenuShelf.app.
# Works with the Command Line Tools alone; Xcode is not required.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/MenuShelf.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MenuShelf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MenuShelf"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature with a fixed identifier. No hardened runtime and no
# sandbox: the app needs to talk to other processes via Accessibility.
# Note: TCC ties an ad-hoc grant to the binary's hash, so after a rebuild
# macOS may ask you to re-enable MenuShelf under Accessibility.
codesign --force --sign - --identifier dev.menushelf.MenuShelf "$APP"

echo "Built $PWD/$APP"
