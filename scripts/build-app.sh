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

# Sign with the "MenuShelf Dev" certificate when it exists (self-signed is
# fine): macOS then keeps the Accessibility and Screen Recording grants across
# rebuilds. Otherwise sign ad hoc, and TCC ties grants to this exact binary,
# so you must re-enable MenuShelf in System Settings after every rebuild.
# No hardened runtime and no sandbox: MenuShelf uses Accessibility.
IDENTITY="${SIGN_IDENTITY:-MenuShelf Dev}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier dev.menushelf.MenuShelf "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - --identifier dev.menushelf.MenuShelf "$APP"
    echo "Signed ad hoc (create a \"$IDENTITY\" code-signing certificate to keep permissions across rebuilds)"
fi

echo "Built $PWD/$APP"
