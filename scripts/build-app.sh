#!/bin/zsh
# Builds "KeyPoint OSC.app" into build/.
#   scripts/build-app.sh             this Mac's architecture, for development
#   UNIVERSAL=1 scripts/build-app.sh  Apple Silicon + Intel, for releases
# Signs with "KeyPoint OSC Development" if that identity exists (permissions then
# survive rebuilds and updates), else ad-hoc. SIGN_ID overrides, e.g. a Developer ID.
# To create the development identity: scripts/make-dev-cert.sh
set -euo pipefail
cd "${0:A:h}/.."
config=${CONFIG:-release}
app="build/KeyPoint OSC.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [[ ${UNIVERSAL:-0} == 1 ]]; then
  slices=()
  for arch in arm64 x86_64; do
    swift build -c $config --product KeyPointOSC --triple $arch-apple-macosx14.0
    slices+=("$(swift build -c $config --triple $arch-apple-macosx14.0 --show-bin-path)/KeyPointOSC")
  done
  lipo -create $slices -output "$app/Contents/MacOS/KeyPointOSC"
else
  swift build -c $config --product KeyPointOSC
  cp "$(swift build -c $config --show-bin-path)/KeyPointOSC" "$app/Contents/MacOS/KeyPointOSC"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"

if [[ -z ${SIGN_ID:-} ]] && security find-identity -p codesigning | grep -q '"KeyPoint OSC Development"'; then
  SIGN_ID="KeyPoint OSC Development"
fi
codesign --force --options runtime --entitlements Resources/KeyPointOSC.entitlements \
  --sign "${SIGN_ID:--}" "$app"
codesign --verify --strict "$app"
echo "Signed with: ${SIGN_ID:-ad-hoc}"
echo "Architectures: $(lipo -archs "$app/Contents/MacOS/KeyPointOSC")"
echo "Built $app"
