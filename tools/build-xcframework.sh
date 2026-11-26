#!/usr/bin/env bash
# Build WebBridgeKit.xcframework from the current checkout.
#
# The result is a *dynamic* framework built with BUILD_LIBRARY_FOR_DISTRIBUTION,
# so its .swiftinterface is tied to the Xcode that produced it. Its public
# interface imports the third-party modules listed in the podspec, therefore
# the consumer must link those same modules at matching versions. The script
# prints that list and refuses to produce a half-finished bundle.
#
# Usage:
#   bash tools/build-xcframework.sh [output-dir]      # default: build/xcframework
#
# Environment:
#   VERSION   optional; only used for the manifest (default: podspec version)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${1:-$ROOT/build/xcframework}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wbk-xcf.XXXXXX")"
SCHEME="WebBridgeKit"

say() { printf '\n\033[0;34m== %s ==\033[0m\n' "$*"; }
ok()  { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
bad() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

command -v xcodebuild >/dev/null || bad "xcodebuild is required"
command -v xcodegen    >/dev/null || bad "xcodegen is required (brew install xcodegen)"
command -v pod         >/dev/null || bad "CocoaPods is required (sudo gem install cocoapods)"
[[ -f WebBridgeKit.podspec ]]    || bad "run this from the framework repository"

VERSION="${VERSION:-$(sed -nE "s/.*s\.version *= *'([^']+)'.*/\1/p" WebBridgeKit.podspec | head -1)}"
[[ -n "$VERSION" ]] || bad "could not read the version from WebBridgeKit.podspec"
XCODE="$(xcodebuild -version | awk '/Xcode/ { print $2 }')"
[[ -n "$XCODE" ]] || bad "could not read the Xcode version"

archive() {
  local sdk="$1"
  local destination="$2"
  local name="$3"
  local label="$4"
  local path="$WORK/$name.xcarchive"
  say "Archiving $label"
  xcodebuild archive -workspace WebBridgeKit.xcworkspace -scheme "$SCHEME" \
    -configuration Release -sdk "$sdk" -destination "$destination" \
    -archivePath "$path" CODE_SIGNING_ALLOWED=NO SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES >"$WORK/$name.log" 2>&1 \
    || { tail -n 40 "$WORK/$name.log"; bad "$label archive failed"; }
  [[ -d "$path/Products/Library/Frameworks/$SCHEME.framework" ]] \
    || bad "$label archive did not produce $SCHEME.framework"
  find "$path/Products/Library/Frameworks/$SCHEME.framework" -name "*.swiftinterface" -print -quit | grep -q . \
    || bad "$label archive has no .swiftinterface; BUILD_LIBRARY_FOR_DISTRIBUTION did not apply"
  ok "$label"
}

say "Generating the project and installing dependencies"
xcodegen generate >"$WORK/xcodegen.log" 2>&1 || { cat "$WORK/xcodegen.log"; bad "xcodegen failed"; }
pod install >"$WORK/pod.log" 2>&1          || { tail -n 20 "$WORK/pod.log"; bad "pod install failed"; }

archive iphoneos        'generic/platform=iOS'           ios "device slice"
archive iphonesimulator 'generic/platform=iOS Simulator' sim "simulator slice"

say "Creating the xcframework"
rm -rf "$OUT/WebBridgeKit.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework \
  -framework "$WORK/ios.xcarchive/Products/Library/Frameworks/$SCHEME.framework" \
  -framework "$WORK/sim.xcarchive/Products/Library/Frameworks/$SCHEME.framework" \
  -output "$OUT/WebBridgeKit.xcframework" >"$WORK/create.log" 2>&1 \
  || { cat "$WORK/create.log"; bad "xcframework creation failed"; }

say "Verifying the bundle"
XCF="$OUT/WebBridgeKit.xcframework"
SLICES=""
while IFS= read -r slice; do
  [[ -f "$XCF/$slice/$SCHEME.framework/$SCHEME" ]] || bad "slice has no binary: $slice"
  SLICES="${SLICES:+$SLICES,}\"$slice\""
  printf '  %-32s %s\n' "$slice" "$(xcrun lipo -info "$XCF/$slice/$SCHEME.framework/$SCHEME" | sed 's/.*are: //; s/.*is architecture: //')"
done < <(plutil -extract AvailableLibraries json -o - "$XCF/Info.plist" \
         | python3 -c 'import json,sys; [print(l["LibraryIdentifier"]) for l in json.load(sys.stdin)]')
[[ -f "$XCF/ios-arm64/$SCHEME.framework/$SCHEME" ]] || bad "missing the ios-arm64 device slice"
[[ "$SLICES" == *simulator* ]] || bad "missing the simulator slice"

say "Recording what the consumer must link"
INTERFACE="$(find "$XCF" -name 'arm64-apple-ios.swiftinterface' | head -1)"
# Keep only the modules the consumer has to supply. Everything an iOS SDK
# ships (system frameworks and the underscore-prefixed runtime modules) is
# resolved by the toolchain and is noise in the manifest.
SYSTEM_MODULES=" AVFoundation AudioToolbox CommonCrypto Compression Contacts ContactsUI CoreBluetooth CoreLocation CoreMotion CryptoKit DeveloperToolsSupport Foundation LinkPresentation LocalAuthentication MachO Network Photos PhotosUI Security Speech Swift SwiftUI SystemConfiguration UIKit UniformTypeIdentifiers UserNotifications Vision WebKit os os.log os.signpost "
IMPORTS=""
IMPORTS_JSON=""
while IFS= read -r module; do
  [[ -n "$module" ]] || continue
  case "$SYSTEM_MODULES" in *" $module "*) continue ;; esac
  case "$module" in _*) continue ;; esac
  IMPORTS="${IMPORTS:+$IMPORTS }$module"
  IMPORTS_JSON="${IMPORTS_JSON:+$IMPORTS_JSON,}\"$module\""
done < <(grep -hE '^import ' "$INTERFACE" | awk '{ print $2 }' | sort -u)
[[ -n "$IMPORTS" ]] || bad "no imports found in $INTERFACE"
cat > "$OUT/MANIFEST.json" <<EOF
{
  "name": "WebBridgeKit",
  "version": "$VERSION",
  "kind": "dynamic-xcframework",
  "builtWith": "Xcode $XCODE",
  "minimumiOS": "15.0",
  "slices": [$SLICES],
  "note": "The public interface imports third-party modules. Link the same modules at the versions in WebBridgeKit.podspec, or a consumer that also links them will hit duplicate symbols.",
  "imports": [$IMPORTS_JSON]
}
EOF
ok "Manifest written to $OUT/MANIFEST.json"

say "Done"
printf '  xcframework: %s\n' "$XCF"
printf '  size:        %s\n' "$(du -sh "$XCF" | cut -f1)"
printf '  built with:  Xcode %s\n' "$XCODE"
printf '\n  This is a dynamic framework whose interface imports: %s\n' "$IMPORTS"
