#!/bin/bash
# Regenerates Packaging/AppIcon.icns from render-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
ICONSET=$(mktemp -d)/AppIcon.iconset
swift render-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "wrote $(pwd)/AppIcon.icns"
