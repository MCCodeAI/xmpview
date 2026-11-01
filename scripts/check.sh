#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" == Darwin ]]; then
  swift test
  ./scripts/build-app.sh
else
  swift test --filter XMPViewCoreTests
  echo "Portable core tests only. ImageIO tests, SwiftUI, .app packaging, and format compatibility require macOS."
fi
