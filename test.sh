#!/bin/bash
# Run the Swift Testing suite on a CLT-only machine (no Xcode).
# swift-testing ships in the CLT toolchain but neither its framework nor its macro plugin
# is on the default search paths, so add them for compile, link, and runtime (rpath).
set -euo pipefail
cd "$(dirname "$0")"
source scripts/toolchain.sh

exec swift test \
  -Xswiftc -F -Xswiftc "$TESTING_FW" \
  -Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS" \
  -Xlinker -F -Xlinker "$TESTING_FW" \
  -Xlinker -rpath -Xlinker "$TESTING_FW" \
  "$@"
