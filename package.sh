#!/bin/bash
# Packages BudSwitch for distribution.
#
#   ./package.sh dmg   drag-to-Applications disk image  (default)
#   ./package.sh pkg   double-click installer
#   ./package.sh both
#
# Neither is notarized — there is no Developer ID certificate on this machine, so the app
# is ad-hoc signed. It runs fine locally, but on any other Mac Gatekeeper will block it
# until the user right-clicks > Open once. See README for the details.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BudSwitch"
APP="build/$APP_NAME.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
DIST="dist"

if [ ! -d "$APP" ]; then
	echo "No $APP — run ./build.sh first." >&2
	exit 1
fi

mkdir -p "$DIST"

make_dmg() {
	local staging="$DIST/.dmg-staging"
	local dmg="$DIST/$APP_NAME-$VERSION.dmg"

	rm -rf "$staging" "$dmg"
	mkdir -p "$staging"

	cp -R "$APP" "$staging/"
	# The drop target that makes the window drag-and-drop rather than just a folder.
	ln -s /Applications "$staging/Applications"

	# A menubar app has no Dock icon and no window on launch, so first run looks like
	# nothing happened. Say where to find it.
	cat > "$staging/READ ME FIRST.txt" <<-EOF
		$APP_NAME $VERSION
		Moves your Bluetooth earbuds between this Mac and your phone.

		═══════════════════════════════════════════════════════════
		INSTALLING
		═══════════════════════════════════════════════════════════

		1. Drag $APP_NAME onto the Applications folder shown here.

		2. IMPORTANT — macOS will block the first launch.
		   You will see "Apple could not verify BudSwitch is free of
		   malware" with only Done and Move to Bin. Click DONE —
		   do NOT move it to the bin.

		   On macOS 15 Sequoia and later:
		     System Settings > Privacy & Security > scroll to the
		     bottom > click "Open Anyway" next to the BudSwitch
		     message, then confirm. Once per machine.

		   On macOS 14 Sonoma:
		     Right-click ${APP_NAME} in Applications > Open > Open.

		   Or, in Terminal:
		     xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app

		   (This appears because the app is not notarized by Apple —
		   that requires a paid Apple Developer account. The app is
		   signed and its signature verifies; it simply is not
		   registered with Apple.)

		3. Allow Bluetooth when asked. Without it the app cannot do
		   anything at all. It is the only permission needed —
		   the keyboard shortcut requires nothing extra.

		4. Look for the headphones icon in your menubar. There is no
		   Dock icon and no window — that icon is the whole app.

		═══════════════════════════════════════════════════════════
		USING IT
		═══════════════════════════════════════════════════════════

		Click the menubar icon to switch by hand, or press
		CONTROL-OPTION-COMMAND-B from anywhere. You can change that
		shortcut by clicking it at the bottom of the panel.

		"Switch automatically" is on by default:

		  • Buds come to the Mac when Brave, Spotify, Music, Safari,
		    Chrome, Zoom, Slack or Teams starts playing.
		  • Buds go back to your phone when the Mac is idle for 5
		    minutes, sleeps, or locks.
		  • Never releases during a call or while audio is playing.

		Uncheck "Switch automatically" for manual-only control.

		═══════════════════════════════════════════════════════════
		REQUIREMENTS
		═══════════════════════════════════════════════════════════

		macOS 14 (Sonoma) or later, Apple Silicon.
		Your earbuds must already be paired to this Mac in
		System Settings > Bluetooth. $APP_NAME switches between
		devices you have paired; it does not pair them for you.

		To uninstall: quit from the menubar, drag $APP_NAME from
		Applications to the Trash.
	EOF

	# Build a writable image first so Finder can record the window layout — icon
	# positions, window size and view options are stored in the volume's .DS_Store, and
	# that can only be written to a mounted read-write disk. Compressing straight from a
	# folder gives a plain file list with no drag-to-Applications affordance.
	local temp_dmg="$DIST/.$APP_NAME-rw.dmg"
	rm -f "$temp_dmg"

	hdiutil create \
		-volname "$APP_NAME" \
		-srcfolder "$staging" \
		-ov -format UDRW \
		-fs HFS+ \
		"$temp_dmg" >/dev/null

	local mount_point="/Volumes/$APP_NAME"
	hdiutil attach "$temp_dmg" -nobrowse -quiet
	# Finder needs a moment after mount before it will accept view settings.
	sleep 2

	osascript <<-APPLESCRIPT >/dev/null 2>&1 || echo "  (window layout skipped — needs Finder access)"
		tell application "Finder"
			-- Close any stale window for this volume first. Finder keeps view state per
			-- open window, and an already-open one silently overrides what we set here.
			try
				close every window whose name is "$APP_NAME"
			end try
			delay 1
			tell disk "$APP_NAME"
				open
				delay 1
				set current view of container window to icon view
				set toolbar visible of container window to false
				set statusbar visible of container window to false
				set the bounds of container window to {200, 120, 720, 460}
				delay 1
				set opts to the icon view options of container window
				set arrangement of opts to not arranged
				set text size of opts to 12
				-- Icon size is deliberately left at 48. Finder resets it on every fresh
				-- mount of a read-only image regardless of what .DS_Store records, so the
				-- positions below are spaced for 48pt icons rather than fighting it.
				set icon size of opts to 48
				delay 1
				-- The app on the left, Applications on the right: the standard layout
				-- everyone already knows how to use.
				set position of item "$APP_NAME.app" of container window to {130, 150}
				set position of item "Applications" of container window to {390, 150}
				set position of item "READ ME FIRST.txt" of container window to {260, 265}
				delay 1
				update without registering applications
				delay 2
				close
			end tell
		end tell
	APPLESCRIPT

	sync
	hdiutil detach "$mount_point" -quiet || hdiutil detach "$mount_point" -force -quiet

	# Compress the laid-out image into the final read-only DMG.
	rm -f "$dmg"
	hdiutil convert "$temp_dmg" -format UDZO -o "$dmg" >/dev/null
	rm -f "$temp_dmg"

	rm -rf "$staging"
	echo "  $dmg"
}

make_pkg() {
	local root="$DIST/.pkg-root"
	local component="$DIST/.component.pkg"
	local pkg="$DIST/$APP_NAME-$VERSION.pkg"

	rm -rf "$root" "$component" "$pkg"
	mkdir -p "$root/Applications"
	cp -R "$APP" "$root/Applications/"

	# Installs to /Applications. No preinstall/postinstall scripts: the app needs no
	# daemon, no privileged helper, and nothing outside its own bundle.
	pkgbuild \
		--root "$root" \
		--identifier "com.budswitch.mac" \
		--version "$VERSION" \
		--install-location / \
		"$component" >/dev/null

	productbuild \
		--package "$component" \
		"$pkg" >/dev/null

	rm -rf "$root" "$component"
	echo "  $pkg"
}

TARGET="${1:-dmg}"
echo "Packaging $APP_NAME ${VERSION}…"

case "$TARGET" in
	dmg) make_dmg ;;
	pkg) make_pkg ;;
	both) make_dmg; make_pkg ;;
	*) echo "Usage: $0 [dmg|pkg|both]" >&2; exit 1 ;;
esac

echo "Done. Not notarized — first launch needs right-click > Open."
