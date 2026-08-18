#!/bin/bash
# Builds BudSwitch.app.
#
# SPM drives compilation (see Package.swift) so new files need no edit here, and the
# Galaxy Buds localisation bundles get processed automatically. This script's job is
# assembling the .app around what SPM produces.
#
# The .app bundle is not optional packaging: a bare executable is killed by TCC on its
# first IOBluetooth call. Launch via `open BudSwitch.app`, never the binary directly.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BudSwitch"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Build each architecture separately and join them, so the app runs on Intel Macs as well
# as Apple Silicon. An arm64-only build simply will not launch on an Intel machine.
echo "Compiling…"
for arch in arm64 x86_64; do
	swift build -c release --arch "$arch" >/dev/null
done

swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1 || true

ARM=$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME
X86=$(swift build -c release --arch x86_64 --show-bin-path)/$APP_NAME
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "$ARM" "$X86"

# SPM emits the processed resources (localisations, assets) as a .bundle beside the
# binary; the app needs it inside Contents/Resources to find them at runtime.
BUNDLE="$(dirname "$ARM")/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$BUNDLE" ]; then
	cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# Ad-hoc signature. Keeps Gatekeeper quiet locally and gives TCC a stable identity.
echo "Signing…"
codesign -s - --force --deep "$APP"

echo "Built $APP"
echo "Launch with:  open $APP"
