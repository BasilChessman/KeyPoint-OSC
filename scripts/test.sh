#!/bin/zsh
# Runs the unit tests. With only the Command Line Tools installed (no Xcode),
# SwiftPM doesn't add the swift-testing framework path, so pass it explicitly.
set -euo pipefail
cd "${0:A:h}/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
extra=()
if ! xcode-select -p | grep -q Xcode.app && [[ -d $FW ]]; then
  extra=(-Xswiftc -F -Xswiftc $FW -Xlinker -F -Xlinker $FW -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $LIB)
fi
exec swift test $extra "$@"
