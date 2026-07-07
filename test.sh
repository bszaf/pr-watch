#!/bin/bash
# Run the Swift Testing suite on a CLT-only machine (no Xcode).
# swift-testing ships in the CLT toolchain's Frameworks dir but isn't on the SDK
# search path, so we add it explicitly for compile, link, and runtime (rpath).
set -euo pipefail
cd "$(dirname "$0")"

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  "$@"
