#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Building the native .app requires macOS and Xcode Command Line Tools." >&2
  exit 1
fi
command -v swift >/dev/null || { echo "Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
swift build -c release --product XMPView
binary_directory="$(swift build -c release --show-bin-path)"
app_directory="$PWD/dist/XMP View.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
install -m 755 "$binary_directory/XMPView" "$app_directory/Contents/MacOS/XMPView"
install -m 644 Resources/Info.plist "$app_directory/Contents/Info.plist"
if command -v codesign >/dev/null; then
  codesign --force --sign - "$app_directory"
  codesign --verify --strict "$app_directory"
fi
echo "Built: $app_directory"
echo 'Launch locally: open "dist/XMP View.app"'
echo 'This local build is ad-hoc signed; public distribution requires Developer ID signing and notarization.'
