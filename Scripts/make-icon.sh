#!/bin/bash
# Regenerates AppIcon.icns from the app's OWN glyph geometry.
#
# The icon is GENERATED, not a hand-drawn asset, so the Finder/Spotlight icon
# and the menu bar mark both come from StowGlyph and cannot drift apart.
# Re-run this after changing the token.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# main.swift naming is required for top-level code.
cp Scripts/render-icon.swift "$WORK/main.swift"

swiftc -O "$WORK/main.swift" \
    Sources/Stow/StowGlyph.swift \
    -o "$WORK/render"

"$WORK/render" "$WORK/AppIcon.iconset" "AppIcon.icns"

echo "AppIcon.icns regenerated ($(wc -c < AppIcon.icns | tr -d ' ') bytes)"
