#!/bin/zsh
# Builds "KeyPoint OSC.app" into build/.
#   scripts/build-app.sh      signs with "KeyPoint OSC Development" if that identity
#                             exists (permissions then survive rebuilds), else ad-hoc
#   SIGN_ID="Developer ID Application: …" scripts/build-app.sh   for distribution
# To create the development identity: scripts/make-dev-cert.sh
set -euo pipefail
cd "${0:A:h}/.."
config=${CONFIG:-release}
swift build -c $config --product KeyPointOSC
bin=$(swift build -c $config --show-bin-path)/KeyPointOSC
app="build/KeyPoint OSC.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/KeyPointOSC"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -z ${SIGN_ID:-} ]] && security find-identity -p codesigning | grep -q '"KeyPoint OSC Development"'; then
  SIGN_ID="KeyPoint OSC Development"
fi
codesign --force --options runtime --entitlements Resources/KeyPointOSC.entitlements \
  --sign "${SIGN_ID:--}" "$app"
echo "Signed with: ${SIGN_ID:-ad-hoc}"
codesign --verify --strict "$app"
echo "Built $app"
