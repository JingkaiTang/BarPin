#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-BarPin}"
BUNDLE_ID="${BUNDLE_ID:-com.jingkaitang.barpin}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
OUT_DIR="${OUT_DIR:-dist}"
DMG_NAME="${DMG_NAME:-${APP_NAME}-${VERSION}.dmg}"
BUILD_DIR="$(mktemp -d /tmp/barpin-build.XXXXXX)"
DMG_DIR="${OUT_DIR}/dmg"
ICON_DIR="${OUT_DIR}/icon"
ICON_PNG="${ICON_DIR}/AppIcon.png"
ICONSET="${ICON_DIR}/AppIcon.iconset"
ICON_ICNS="${OUT_DIR}/AppIcon.icns"

cleanup() {
  rm -rf "${BUILD_DIR}" "${DMG_DIR}" "${ICON_DIR}"
}
trap cleanup EXIT

mkdir -p "${OUT_DIR}"

# Build release binary
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache TMPDIR=/tmp \
  swift build -c release --build-path "${BUILD_DIR}" --disable-sandbox

# Build app icon
mkdir -p "${ICON_DIR}"
swift "${PWD}/scripts/make-icon.swift" "${ICON_PNG}"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
sips -z 16 16 "${ICON_PNG}" --out "${ICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_PNG}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_PNG}" --out "${ICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_PNG}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_PNG}" --out "${ICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_PNG}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_PNG}" --out "${ICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_PNG}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_PNG}" --out "${ICONSET}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_PNG}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET}" -o "${ICON_ICNS}"

# Create .app bundle
APP_PATH="${OUT_DIR}/${APP_NAME}.app"
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

cp "${BUILD_DIR}/arm64-apple-macosx/release/${APP_NAME}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
cp "${ICON_ICNS}" "${APP_PATH}/Contents/Resources/AppIcon.icns"

cat <<PLIST > "${APP_PATH}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Create DMG source folder
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"
cp -R "${APP_PATH}" "${DMG_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_DIR}/Applications"

# Build DMG
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_DIR}" -ov -format UDZO "${OUT_DIR}/${DMG_NAME}"

printf "\nDone:\n  %s\n  %s\n" "${APP_PATH}" "${OUT_DIR}/${DMG_NAME}"
