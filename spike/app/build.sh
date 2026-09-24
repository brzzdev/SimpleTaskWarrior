#!/bin/zsh
# Builds, bundles and signs the spike app as a sandboxed, hardened Developer ID build.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64
app=../build/STWSpike.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp "$(swift build -c release --arch arm64 --show-bin-path)/SpikeApp" $app/Contents/MacOS/
cp Bundle/Info.plist $app/Contents/
codesign --force --options runtime --timestamp=none \
	--entitlements Bundle/Spike.entitlements \
	--sign "Developer ID Application: Paul Breeze (FSV65W3H68)" $app
codesign --verify --strict $app
