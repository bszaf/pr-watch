# Sourced by build.sh / test.sh. CLT-only machines need two workarounds that Xcode doesn't:
#  - From the macOS 27 SDK on, SwiftUI's @State is a macro whose plugin (SwiftUIMacros)
#    ships only with Xcode, so pin SDKROOT to the newest CLT SDK whose @State isn't a macro.
#  - swift-testing's macro plugin isn't on the default plugin search path.
CLT=/Library/Developer/CommandLineTools
TESTING_FW="$CLT/Library/Developer/Frameworks"
TESTING_PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"

if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "$CLT" ] \
   && [ ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
  for sdk in $(ls -d "$CLT"/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
    [ -L "$sdk" ] && continue
    if ! grep -qs 'type: "StateMacro"' "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface; then
      export SDKROOT="$sdk"
      echo "==> using SDK $(basename "$sdk") (newer CLT SDKs need Xcode's SwiftUIMacros)"
      break
    fi
  done
fi
