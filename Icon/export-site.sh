#!/bin/bash
# Exports the icon for the website into Icon/export/:
#   tacet-icon-1024.png, tacet-icon-512.png  squircle with transparent margin (as on macOS)
#   apple-touch-icon.png (180)               full bleed: iOS rounds it itself
#   favicon-32.png, favicon-64.png, favicon.ico (16/32/48)
set -euo pipefail
cd "$(dirname "$0")/.."
V="${VARIANT:-graphite}"
OUT=Icon/export
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
swiftc -O -o "$TMP/make-icon" Icon/make-icon.swift
I="$TMP/make-icon"
"$I" png "$V" 1024 "$OUT/tacet-icon-1024.png" masked
"$I" png "$V" 512 "$OUT/tacet-icon-512.png" masked
"$I" png "$V" 180 "$OUT/apple-touch-icon.png"
# Favicons: the squircle fills more of the tile than on macOS's grid, so it
# stays legible at 16-32 px: render masked at 1.25x and crop the margin.
for px in 16 32 48 64; do
    big=$(( px * 1024 / 824 + 1 ))
    "$I" png "$V" "$big" "$TMP/f$px-big.png" masked
    sips -c "$px" "$px" "$TMP/f$px-big.png" --out "$TMP/f$px.png" >/dev/null
done
cp "$TMP/f32.png" "$OUT/favicon-32.png"
cp "$TMP/f64.png" "$OUT/favicon-64.png"
python3 - "$TMP/f16.png" "$TMP/f32.png" "$TMP/f48.png" "$OUT/favicon.ico" <<'PY'
import struct, sys
# ICO with embedded PNGs (supported by every current browser).
files, out = sys.argv[1:-1], sys.argv[-1]
blobs = [open(f, 'rb').read() for f in files]
sizes = [struct.unpack('>II', b[16:24])[0] for b in blobs]
header = struct.pack('<HHH', 0, 1, len(blobs))
offset = 6 + 16 * len(blobs)
entries = b''
for size, blob in zip(sizes, blobs):
    entries += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(blob), offset)
    offset += len(blob)
open(out, 'wb').write(header + entries + b''.join(blobs))
PY
ls -la "$OUT"
