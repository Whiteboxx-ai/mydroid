#!/bin/bash
# Builds Mydroid.app (ad-hoc signed) and mydroid-test-server into $OUT (default: build/ at the repo root).
# adb (Android platform-tools) is copied into Contents/Resources/adb for Mac call audio. Set MYDROID_ADB to use another copy.
# Check the platform-tools licence terms before any public distribution of this app.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MAC_DIR/.." && pwd)"
BUILD="${OUT:-$ROOT/build}"
APP="$BUILD/Mydroid.app"
VERSION="${MYDROID_VERSION:-0.1.0}"
BUILD_NUMBER="${MYDROID_BUILD:-$(date +%Y%m%d%H%M)}"

cd "$MAC_DIR"
# MYDROID_UNIVERSAL=1 builds for Apple silicon and Intel (what releases ship).
ARCHS=()
[ "${MYDROID_UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Mydroid" "$APP/Contents/MacOS/Mydroid"
# The native messaging helper the browser extension starts (PROTOCOL.md 14.3), and the extension itself (load it unpacked from Resources/extension).
cp "$BIN_DIR/mydroid-nmhost" "$APP/Contents/MacOS/mydroid-nmhost"
if [ -d "$ROOT/extension" ]; then
  mkdir -p "$APP/Contents/Resources/extension"
  rsync -a --exclude test --exclude .DS_Store "$ROOT/extension/" "$APP/Contents/Resources/extension/"
else
  echo "warning: no extension/ folder; the bundle has no browser extension" >&2
fi

# adb for Mac call audio (PROTOCOL.md 8). A single universal binary that links only system libraries; any other library it
# links (none today) is copied next to it and re-pointed, so the bundle never depends on the SDK folder.
ADB_SRC="${MYDROID_ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
if [ -x "$ADB_SRC" ]; then
  cp "$ADB_SRC" "$APP/Contents/Resources/adb"
  chmod 755 "$APP/Contents/Resources/adb"
  while IFS= read -r lib; do
    case "$lib" in
      /usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*|"") ;;
      *)
        echo "adb links a non-system library: $lib" >&2
        mkdir -p "$APP/Contents/Resources/lib"
        cp "$lib" "$APP/Contents/Resources/lib/$(basename "$lib")"
        install_name_tool -change "$lib" "@executable_path/lib/$(basename "$lib")" "$APP/Contents/Resources/adb"
        codesign --force -s - "$APP/Contents/Resources/lib/$(basename "$lib")"
        ;;
    esac
  done < <(otool -L "$APP/Contents/Resources/adb" | grep -E '^[[:space:]]' | awk '{print $1}' | sort -u)
  codesign --force -s - "$APP/Contents/Resources/adb"
  ADB_NOTE="$("$APP/Contents/Resources/adb" version | head -1)"
else
  echo "warning: adb not found at $ADB_SRC; Mac call audio will say it isn't available in this build" >&2
  ADB_NOTE="no adb"
fi

# App icon: the .icns is cut from assets/icon-1024.png (regenerate that with scripts/make-icons.py).
ICONSET="$(mktemp -d)/Mydroid.iconset"
ICON_KEY=""
mkdir -p "$ICONSET"
ok=1
for base in 16 32 128 256 512; do
  sips -z $base $base "$ROOT/assets/icon-1024.png" --out "$ICONSET/icon_${base}x${base}.png" >/dev/null || ok=0
  sips -z $((base * 2)) $((base * 2)) "$ROOT/assets/icon-1024.png" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null || ok=0
done
if [ "$ok" = 1 ] && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Mydroid.icns"; then
  ICON_KEY="<key>CFBundleIconFile</key><string>Mydroid</string>"
else
  echo "warning: icon generation failed; building without an icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Mydroid</string>
  <key>CFBundleIdentifier</key><string>com.mydroid.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Mydroid</string>
  <key>CFBundleDisplayName</key><string>Mydroid</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  $ICON_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Mydroid talks to your Android phone over your local network to sync notifications, photos, files and the clipboard, and lets your phone send things to this Mac with Quick Share.</string>
  <key>NSBonjourServices</key><array><string>_mydroid._tcp</string><string>_FC9F5ED42C8A._tcp</string></array>
  <key>NSDesktopFolderUsageDescription</key><string>So your phone can browse and open files from your Desktop, if you share it in Mydroid.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>So your phone can browse and open files from your Documents folder, if you share it in Mydroid.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>So your phone can browse files in your Downloads folder, and so files your phone sends are saved there.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Lets your phone know your Mac is nearby, so it can save battery.</string>
  <key>NSPhotoLibraryAddUsageDescription</key><string>Mydroid can add the photos from your phone to Apple Photos.</string>
  <key>NSCameraUsageDescription</key><string>To read the transfer QR codes from Google Authenticator. Nothing is saved.</string>
  <key>NSMicrophoneUsageDescription</key><string>So you can talk on phone calls through your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>So Mydroid can tell when a Keynote slideshow is playing and offer the clicker on your phone, and read the address of your browser's current tab so a code from your phone goes only to the right site. It also lets Mydroid tell Spotify on this Mac which song to play when you continue a song from your phone.</string>
  <key>NSFocusStatusUsageDescription</key><string>Mydroid can hold back banners while a Focus is on.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.mydroid.mac.send</string>
      <key>CFBundleURLSchemes</key><array><string>mydroid</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Send to Phone</string></dict>
      <key>NSMessage</key><string>sendToPhone</string>
      <key>NSPortName</key><string>Mydroid</string>
      <key>NSSendTypes</key>
      <array><string>public.utf8-plain-text</string><string>NSStringPboardType</string><string>public.url</string></array>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>Mydroid</string>
</dict>
</plist>
PLIST

# macOS records a permission (Accessibility, ...) against the app's designated requirement. An ad-hoc signature's default one is the
# exact build (cdhash), so every rebuild or update would lose the permission. Naming the app by its identifier keeps it across updates.
# The helper first, with its own default requirement: a requirement given with --deep would be forced onto every nested binary.
codesign --force -s - "$APP/Contents/MacOS/mydroid-nmhost"
codesign --force -s - -r='designated => identifier "com.mydroid.mac"' "$APP"
codesign --verify --deep --strict "$APP"
[ -x "$APP/Contents/MacOS/mydroid-nmhost" ] || { echo "mydroid-nmhost is missing from the bundle" >&2; exit 1; }
plutil -lint "$APP/Contents/Info.plist"

mkdir -p "$BUILD"
cp "$BIN_DIR/mydroid-test-server" "$BUILD/mydroid-test-server"

echo "Built $APP ($ADB_NOTE)"
echo "Built $BUILD/mydroid-test-server"
