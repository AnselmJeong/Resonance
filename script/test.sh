#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEV_DIR="$(xcode-select -p)"
FRAMEWORK_DIR="$DEV_DIR/Library/Developer/Frameworks"
if [ -d "$FRAMEWORK_DIR/Testing.framework" ]; then
  swift test --scratch-path .build/tests --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc "$FRAMEWORK_DIR" -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" "$@"
else
  swift test --disable-xctest --enable-swift-testing "$@"
fi
