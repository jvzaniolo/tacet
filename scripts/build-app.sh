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

# Build number and links. Beta builds (BETA=1) also get an expiry date
# (EXPIRES_DAYS after the build, default 60; 0 = already expired, to test the
# "beta has ended" window), and sign with the "Tacet Beta" certificate
# (scripts/make-beta-cert.sh) unless SIGN_IDENTITY says otherwise.
PB=/usr/libexec/PlistBuddy
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
SITE_URL="${SITE_URL:-https://gettacet.com}"
$PB -c "Add :TacetSiteURL string $SITE_URL" "$APP/Contents/Info.plist"
if [ "${BETA:-0}" = "1" ]; then
    EXPIRES_DAYS="${EXPIRES_DAYS:-60}"
    EXPIRY="$(date -u -v+"${EXPIRES_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
    $PB -c "Add :TacetBetaExpiry string $EXPIRY" "$APP/Contents/Info.plist"
    BETA_NUMBER="${BETA_NUMBER:-1}"
    $PB -c "Add :TacetBetaNumber string $BETA_NUMBER" "$APP/Contents/Info.plist"
    FEEDBACK_URL="${FEEDBACK_URL:-https://gettacet.com/feedback}"
    SIGN_IDENTITY="${SIGN_IDENTITY:-Tacet Beta}"
    echo "Beta $BETA_NUMBER, build $BUILD_NUMBER, expires $EXPIRY"
fi
if [ -n "${FEEDBACK_URL:-}" ]; then
    $PB -c "Add :TacetFeedbackURL string $FEEDBACK_URL" "$APP/Contents/Info.plist"
fi
cp Support/Tacet.icns "$APP/Contents/Resources/Tacet.icns"   # from Icon/make-icns.sh
# Translations: Resources/<lang>.lproj/Localizable.strings, looked up in the
# main bundle (String Catalogs need xcstringstool, which only Xcode ships).
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Sign with a stable code-signing identity when there is one (self-signed is
# fine): SIGN_IDENTITY, else the first identity whose name starts with
# "Tacet" (e.g. "Tacet Beta" from scripts/make-beta-cert.sh). Otherwise sign ad
# hoc. Tacet needs no TCC permission; its one grant is the security-scoped
# bookmark to the Control Center settings file.
# A self-signed certificate is "not trusted", so `find-identity -v` hides
# it; list without -v.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning | sed -n -E 's/.*"(Tacet[^"]*)".*/\1/p' | head -1)}"
if [ "${BETA:-0}" = "1" ] && ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "No \"$IDENTITY\" certificate: run scripts/make-beta-cert.sh first (betas must all share one identity)." >&2
    exit 1
fi
if [ -n "$IDENTITY" ] && security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    # Hardened runtime (review 3.1): needed for notarization later, and stops
    # DYLD_INSERT_LIBRARIES from riding on Tacet's file grant. Tacet loads no
    # third-party code and dlsym into CoreFoundation is allowed, so no
    # entitlements are needed.
    codesign --force --options runtime --sign "$IDENTITY" --identifier app.gettacet.Tacet "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --options runtime --sign - --identifier app.gettacet.Tacet "$APP"
    echo "Signed ad hoc (create a \"Tacet Dev\" code-signing certificate for a stable identity)"
fi

echo "Built $PWD/$APP"

# Installs to /Applications, where a shipping app lives. Since the switch to
# the System Settings switches (NOTES §13) nothing requires it any more; the
# old restriction did (§11 E7). Only with INSTALL=1 (or scripts/install.sh):
# it quits the running Tacet and replaces /Applications/Tacet.app (review 3.2).
if [ "${INSTALL:-0}" = "1" ]; then
    DEST="/Applications/Tacet.app"
    # A normal quit (SIGTERM) turns hidden apps back on before the swap.
    if pkill -TERM -x Tacet; then sleep 1; fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed $DEST"
fi
