#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipShelf"
BUNDLE_ID="com.clipshelf.app"
BUILD_CONFIG="${1:-release}"

echo "Building ${APP_NAME} (${BUILD_CONFIG})..."
cd "${ROOT_DIR}"
swift build -c "${BUILD_CONFIG}"

BIN_DIR="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BIN_DIR}/${APP_NAME}_${APP_NAME}.bundle"

APP_DIR="${ROOT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

if [[ -d "${RESOURCE_BUNDLE}" ]]; then
  cp -R "${RESOURCE_BUNDLE}" "${RESOURCES_DIR}/"
fi

# Bundle optional gitignored local sound overrides if present
if [[ -d "${ROOT_DIR}/LocalSounds" ]]; then
  mkdir -p "${RESOURCES_DIR}/LocalSounds"
  cp -f "${ROOT_DIR}/LocalSounds/"*.aiff "${RESOURCES_DIR}/LocalSounds/" 2>/dev/null || true
  cp -f "${ROOT_DIR}/LocalSounds/"*.wav "${RESOURCES_DIR}/LocalSounds/" 2>/dev/null || true
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
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
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS Accessibility & local execution work smoothly
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "Built: ${APP_DIR}"
