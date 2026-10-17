#!/bin/bash
# Builds a beta (BETA=1, signed with "Tacet Beta") and packs it as
# build/Tacet-<version>-beta.<n>.zip: Tacet.app plus "How to Install.txt".
# A zip instead of a DMG: opening an unnotarized DMG makes macOS warn once for
# the DMG and again for the app; a zip only warns for the app.
#   BETA_NUMBER=2 scripts/make-beta-zip.sh                 # build and pack
#   FROM_DMG=build/Tacet-0.1.0-beta.2.dmg scripts/make-beta-zip.sh   # repack a released DMG's app
# Other options are passed to the build: EXPIRES_DAYS, FEEDBACK_URL, SITE_URL.
set -euo pipefail
cd "$(dirname "$0")/.."
STAGE="$(mktemp -d)"
MOUNT=""
trap '[ -n "$MOUNT" ] && hdiutil detach -quiet "$MOUNT"; rm -rf "$STAGE"' EXIT
if [ -n "${FROM_DMG:-}" ]; then
    MOUNT="$(mktemp -d)"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$FROM_DMG"
    APP="$MOUNT/Tacet.app"
else
    export BETA_NUMBER="${BETA_NUMBER:-1}"
    BETA=1 INSTALL=0 ./scripts/build-app.sh
    APP=build/Tacet.app
fi
PB=/usr/libexec/PlistBuddy
VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NUMBER="$($PB -c 'Print :TacetBetaNumber' "$APP/Contents/Info.plist")"
EXPIRY="$($PB -c 'Print :TacetBetaExpiry' "$APP/Contents/Info.plist")"
codesign --verify --strict "$APP"

expiry() { LC_TIME="$1" date -j -u -f %Y-%m-%dT%H:%M:%SZ "$EXPIRY" "+$2" | sed 's/^ //; s/  / /'; }
NAME="Tacet-$VERSION-beta.$NUMBER"
mkdir "$STAGE/$NAME"
ditto "$APP" "$STAGE/$NAME/Tacet.app"
sed -e "s/{{EXPIRES_EN}}/$(expiry en_US.UTF-8 '%B %e, %Y')/" \
    -e "s/{{EXPIRES_PT}}/$(expiry pt_BR.UTF-8 '%e de %B de %Y')/" \
    -e "s/{{EXPIRES_ES}}/$(expiry es_ES.UTF-8 '%e de %B de %Y')/" \
    "Support/How to Install.txt" > "$STAGE/$NAME/How to Install.txt"
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/$NAME" "$ZIP"
echo "Built $PWD/$ZIP"
