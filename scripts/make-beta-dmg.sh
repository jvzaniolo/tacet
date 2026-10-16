#!/bin/bash
# Builds a beta (BETA=1, signed with "Tacet Beta") and packs it as
# build/Tacet-<version>-beta.dmg: Tacet.app plus a link to /Applications.
#   scripts/make-beta-dmg.sh                    # 60-day beta
#   EXPIRES_DAYS=30 FEEDBACK_URL=mailto:… scripts/make-beta-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BETA=1 INSTALL="${INSTALL:-0}" ./scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Tacet.app/Contents/Info.plist)"
DMG="build/Tacet-$VERSION-beta.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/Tacet.app "$STAGE/Tacet.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Tacet $VERSION beta" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --force --sign "${SIGN_IDENTITY:-Tacet Beta}" "$DMG"
echo "Built $PWD/$DMG"
