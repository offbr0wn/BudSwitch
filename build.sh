#!/bin/bash
# Builds BudSwitch.app.
#
# Uses swiftc directly rather than xcodebuild, because `xcode-select -p` on this machine
# points at /Library/Developer/CommandLineTools and xcodebuild refuses to run. To switch
# to a full Xcode toolchain instead:
#
#   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#
# The .app bundle is not optional packaging: a bare executable is killed by TCC on its
# first IOBluetooth call. The app must also be launched via LaunchServices (`open`), not
# executed directly, or macOS never grants Bluetooth access.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="BudSwitch"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# The app is LSUIElement so it has no Dock icon, but Finder, Get Info and the
# force-quit list still use this. Regenerate with:
#   swiftc -O Resources/makeicon.swift -o /tmp/makeicon -framework AppKit
#   /tmp/makeicon /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

SOURCES=(
	BudSwitch/Core/Logger.swift \
	BudSwitch/Core/Arbiter.swift \
	BudSwitch/Core/Hotkey.swift \
	BudSwitch/Monitors/AudioRouteProbe.swift \
	BudSwitch/Monitors/AudioMonitor.swift \
	BudSwitch/Monitors/AppFocusMonitor.swift \
	BudSwitch/Monitors/IdleMonitor.swift \
	BudSwitch/Monitors/PowerMonitor.swift \
	BudSwitch/Bluetooth/DeviceStore.swift \
	BudSwitch/Bluetooth/BluetoothController.swift \
	BudSwitch/App/AppState.swift \
	BudSwitch/UI/HUD.swift \
	BudSwitch/UI/ShortcutRecorder.swift \
	BudSwitch/UI/MenuView.swift \
	BudSwitch/App/BudSwitchApp.swift
)

FRAMEWORKS=(-framework SwiftUI -framework IOBluetooth -framework CoreAudio -framework AppKit)

# Build each architecture separately and join them, so the app runs on Intel Macs as well
# as Apple Silicon. An arm64-only build simply will not launch on an Intel machine, which
# matters for something meant to be shared.
echo "Compiling…"
for arch in arm64 x86_64; do
	swiftc -O -parse-as-library \
		-target "$arch-apple-macosx14.0" \
		"${FRAMEWORKS[@]}" \
		-o "$BUILD_DIR/$APP_NAME-$arch" \
		"${SOURCES[@]}"
done

lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
	"$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64"
rm -f "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64"

# Ad-hoc signature. Keeps Gatekeeper quiet locally and gives TCC a stable identity.
echo "Signing…"
codesign -s - --force --deep "$APP"

echo "Built $APP"
echo "Launch with:  open $APP"
