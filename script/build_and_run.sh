#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
APP_NAME="Resonance"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "$MODE" in run|--verify|--build|--dmg|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [run|--verify|--build|--dmg|--debug|--logs|--telemetry] [--sample]" >&2; exit 2;; esac
CONFIGURATION="debug"
if [ "$MODE" = "--dmg" ]; then CONFIGURATION="release"; fi
if [ "$MODE" != "--build" ] && [ "$MODE" != "--dmg" ]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
swift build --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
STAGING="$ROOT_DIR/dist/$APP_NAME.staging.app"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources" "$STAGING/Contents/Frameworks"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
# The LGPL SMB library remains dynamically replaceable, with no Homebrew dependency.
cp "$BIN_DIR/libAMSMB2.dylib" "$STAGING/Contents/Frameworks/"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$STAGING/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$STAGING/Contents/Frameworks/libAMSMB2.dylib"
mkdir -p "$STAGING/Contents/Resources/Licenses"
cp "$ROOT_DIR/.build/checkouts/AMSMB2/LICENSE" "$STAGING/Contents/Resources/Licenses/AMSMB2-LGPL-2.1.txt"
cp "$ROOT_DIR/Resources/SMB-NOTICE.txt" "$STAGING/Contents/Resources/Licenses/"
# Include the exact library source and build manifests with distributed binaries.
tar -czf "$STAGING/Contents/Resources/Licenses/AMSMB2-4.0.3-source.tar.gz" -C "$ROOT_DIR/.build/checkouts/AMSMB2" AMSMB2 Dependencies Package.swift Package@swift-6.0.swift LICENSE README.md
for resource in "$BIN_DIR"/*.bundle; do if [ -d "$resource" ]; then cp -R "$resource" "$STAGING/Contents/Resources/"; fi; done
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then cp "$ROOT_DIR/Resources/AppIcon.icns" "$STAGING/Contents/Resources/"; fi
cp "$ROOT_DIR/Resources/Credits.rtf" "$STAGING/Contents/Resources/"
cat > "$STAGING/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Resonance</string>
<key>CFBundleIdentifier</key><string>local.Resonance</string>
<key>CFBundleName</key><string>Resonance</string>
<key>CFBundleDisplayName</key><string>Resonance</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.3</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>SMB 음악 서버에서 태그와 음원을 읽고 선택한 AirPlay 출력으로 음악을 재생합니다.</string>
<key>NSBonjourServices</key><array><string>_raop._tcp</string></array>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$STAGING"
codesign --verify --deep --strict "$STAGING"
plutil -lint "$STAGING/Contents/Info.plist"
rm -rf "$APP_BUNDLE"
mv "$STAGING" "$APP_BUNDLE"
# Keep the installed copy in ~/Applications in step with the build, and launch that one.
INSTALLED="$HOME/Applications/$APP_NAME.app"
if [ "$MODE" != "--build" ] && [ "$MODE" != "--dmg" ] && [ -d "$INSTALLED" ]; then rm -rf "$INSTALLED"; ditto "$APP_BUNDLE" "$INSTALLED"; APP_BUNDLE="$INSTALLED"; fi
ARGS=()
if [ "${2:-}" = "--sample" ]; then ARGS=(--import "$ROOT_DIR/Alexandre Tharaud"); fi
open_app() { if [ "${#ARGS[@]}" -gt 0 ]; then /usr/bin/open -n "$APP_BUNDLE" --args "${ARGS[@]}"; else /usr/bin/open -n "$APP_BUNDLE"; fi; }
case "$MODE" in
  --build) echo "$APP_BUNDLE" ;;
  --dmg)
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
    DMG="$ROOT_DIR/dist/$APP_NAME-$VERSION.dmg"
    DMG_STAGING="$(mktemp -d "$ROOT_DIR/dist/dmg.XXXXXX")"
    trap 'rm -rf "$DMG_STAGING"' EXIT
    ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create -ov -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -format UDZO "$DMG"
    hdiutil verify "$DMG"
    echo "$DMG"
    ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) open_app; /usr/bin/log stream --info --style compact --predicate 'process == "Resonance"' ;;
  --telemetry) open_app; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.Resonance"' ;;
  --verify) open_app; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "App launched: $APP_BUNDLE" ;;
  run) open_app ;;
esac
