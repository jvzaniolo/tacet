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
# fine): a stable identity keeps macOS grants across rebuilds. Otherwise sign
# ad hoc. MenuShelf needs no TCC permission; its one grant is the
# security-scoped bookmark to the Control Center settings file.
# A self-signed certificate is "not trusted", so `find-identity -v` hides
# it; list without -v. Any identity whose name starts with "MenuShel"
# matches (covers "MenuShelf Dev" and a "MenuShel Dev" typo).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning | sed -n 's/.*"\(MenuShel[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:-MenuShelf Dev}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier dev.menushelf.MenuShelf "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - --identifier dev.menushelf.MenuShelf "$APP"
    echo "Signed ad hoc (create a \"$IDENTITY\" code-signing certificate to keep permissions across rebuilds)"
fi

echo "Built $PWD/$APP"

# Installs to /Applications, where a shipping app lives. Since the switch to
# the System Settings switches (NOTES §13) nothing requires it any more; the
# old restriction did (§11 E7). INSTALL=0 skips this step.
if [ "${INSTALL:-1}" = "1" ]; then
    DEST="/Applications/MenuShelf.app"
    osascript -e 'quit app id "dev.menushelf.MenuShelf"' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed $DEST"
fi
