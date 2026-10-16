#!/bin/bash
# Regenerates Support/Tacet.icns from Icon/make-icon.swift (variant "glass").
# .icns holds one appearance; dark/tinted variants would need an asset
# catalog or an Icon Composer .icon, which only Xcode's actool compiles.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/make-icon" Icon/make-icon.swift
"$TMP/make-icon" iconset glass "$TMP/Tacet.iconset"
iconutil -c icns "$TMP/Tacet.iconset" -o Support/Tacet.icns
echo "Wrote Support/Tacet.icns"
