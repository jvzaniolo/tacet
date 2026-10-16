#!/bin/bash
# Builds Tacet with SwiftPM and wraps the binary in build/Tacet.app.
# Works with the Command Line Tools alone; Xcode is not required.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Tacet.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Tacet"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tacet"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable code-signing identity when there is one (self-signed is
# fine): SIGN_IDENTITY, else the first identity whose name starts with "Tacet"
# or "MenuShel" (the certificate made under the old name). Otherwise sign ad
# hoc. Tacet needs no TCC permission; its one grant is the security-scoped
# bookmark to the Control Center settings file.
# A self-signed certificate is "not trusted", so `find-identity -v` hides
# it; list without -v.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning | sed -n -E 's/.*"((Tacet|MenuShel)[^"]*)".*/\1/p' | head -1)}"
if [ -n "$IDENTITY" ] && security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier app.gettacet.Tacet "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - --identifier app.gettacet.Tacet "$APP"
    echo "Signed ad hoc (create a \"Tacet Dev\" code-signing certificate for a stable identity)"
fi

echo "Built $PWD/$APP"

# Installs to /Applications, where a shipping app lives. Since the switch to
# the System Settings switches (NOTES §13) nothing requires it any more; the
# old restriction did (§11 E7). INSTALL=0 skips this step.
if [ "${INSTALL:-1}" = "1" ]; then
    DEST="/Applications/Tacet.app"
    # A normal quit (SIGTERM) turns hidden apps back on before the swap.
    if pkill -TERM -x Tacet; then sleep 1; fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed $DEST"
fi
