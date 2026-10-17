#!/bin/bash
set -euo pipefail
VIEWER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWER_PROJECT="$(cd "$VIEWER_ROOT/.." && pwd)"
VIEWER_LOCAL="$VIEWER_PROJECT/local/iphone-viewer-check"
mkdir -p "$VIEWER_LOCAL"
swift test --package-path "$VIEWER_ROOT" --scratch-path "$VIEWER_LOCAL/core-build"
# The optional internet relay address lives in ignored local configuration, never in Git.
RELAY_URL=""
if [ -f "$VIEWER_PROJECT/local/relay.env" ]; then RELAY_URL="$(sed -n 's/^RELAY_URL=//p' "$VIEWER_PROJECT/local/relay.env" | head -1)"; fi
xcodebuild build -project "$VIEWER_ROOT/AndroidViewer.xcodeproj" -scheme AndroidViewer \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$VIEWER_LOCAL/SignedBuild" \
    -clonedSourcePackagesDirPath "$VIEWER_LOCAL/packages" AV_RELAY_URL="$RELAY_URL" -quiet
codesign --verify --deep --strict "$VIEWER_LOCAL/SignedBuild/Build/Products/Debug-iphoneos/AndroidViewer.app"
