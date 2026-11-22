#!/bin/bash
set -e

# Define directories
APP_NAME="MacHead"
APP_DIR="${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"

echo "Building MacHead (Universal Binary)..."

# Clean previous build
if [ -d "${APP_DIR}" ]; then
  rm -rf "${APP_DIR}"
fi

# Create directory structure
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

SDK_PATH=$(xcrun --show-sdk-path)
echo "Using SDK: ${SDK_PATH}"

# Compile for Apple Silicon (arm64)
echo "Compiling for arm64 (Apple Silicon)..."
swiftc \
  -target arm64-apple-macos12.0 \
  -sdk "${SDK_PATH}" \
  -O \
  -import-objc-header Sources/VirtualDisplayBridge.h \
  -o "${MACOS_DIR}/${APP_NAME}_arm64" \
  -framework SwiftUI \
  -framework Cocoa \
  -framework IOKit \
  -framework CoreGraphics \
  -framework CoreAudio \
  Sources/*.swift

# Compile for Intel (x86_64)
echo "Compiling for x86_64 (Intel)..."
swiftc \
  -target x86_64-apple-macos12.0 \
  -sdk "${SDK_PATH}" \
  -O \
  -import-objc-header Sources/VirtualDisplayBridge.h \
  -o "${MACOS_DIR}/${APP_NAME}_x86_64" \
  -framework SwiftUI \
  -framework Cocoa \
  -framework IOKit \
  -framework CoreGraphics \
  -framework CoreAudio \
  Sources/*.swift

# Combine into a Universal Binary via lipo
echo "Merging architectures into a Universal Binary..."
lipo -create \
  "${MACOS_DIR}/${APP_NAME}_arm64" \
  "${MACOS_DIR}/${APP_NAME}_x86_64" \
  -output "${MACOS_DIR}/${APP_NAME}"

# Clean up single-architecture binaries
rm "${MACOS_DIR}/${APP_NAME}_arm64" "${MACOS_DIR}/${APP_NAME}_x86_64"

# Copy Info.plist to the bundle
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Parse arguments: [version] [build] [--no-install]
# --no-install: build only, skip installing to /Applications and relaunching (for contributors / CI)
NO_INSTALL=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--no-install" ]; then
    NO_INSTALL=1
  else
    ARGS+=("$arg")
  fi
done

# Set version and build if arguments are provided
VERSION="${ARGS[0]:-1.0.0}"
BUILD="${ARGS[1]:-1}"

echo "Setting bundle version in Info.plist: Version ${VERSION} (Build ${BUILD})"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${APP_DIR}/Contents/Info.plist"

# Copy AppIcon, Dashboard, Login HTML, and monitoring binaries to resources
mkdir -p "${APP_DIR}/Contents/Resources"
cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
cp Resources/Dashboard.html "${APP_DIR}/Contents/Resources/Dashboard.html"
cp Resources/Login.html "${APP_DIR}/Contents/Resources/Login.html"
if [ -f "Resources/nezha-agent" ]; then
  cp Resources/nezha-agent "${APP_DIR}/Contents/Resources/nezha-agent"
  chmod +x "${APP_DIR}/Contents/Resources/nezha-agent"
fi
if [ -f "Resources/serverstatus-client" ]; then
  cp Resources/serverstatus-client "${APP_DIR}/Contents/Resources/serverstatus-client"
  chmod +x "${APP_DIR}/Contents/Resources/serverstatus-client"
fi
if [ -f "Resources/frpc" ]; then
  cp Resources/frpc "${APP_DIR}/Contents/Resources/frpc"
  chmod +x "${APP_DIR}/Contents/Resources/frpc"
fi
if [ -f "Resources/cloudflared" ]; then
  cp Resources/cloudflared "${APP_DIR}/Contents/Resources/cloudflared"
  chmod +x "${APP_DIR}/Contents/Resources/cloudflared"
fi
if [ -f "Resources/tailcat" ]; then
  cp Resources/tailcat "${APP_DIR}/Contents/Resources/tailcat"
  chmod +x "${APP_DIR}/Contents/Resources/tailcat"
fi
# devtunnel 为微软专有 EULA 组件，禁止捆绑再分发：CI 不下载、仓库不入库。
# 本地开发构建若存在该文件会顺带打包；正式分发由用户在 App 内一键安装获取。
if [ -f "Resources/devtunnel" ]; then
  cp Resources/devtunnel "${APP_DIR}/Contents/Resources/devtunnel"
  chmod +x "${APP_DIR}/Contents/Resources/devtunnel"
fi

# Apply ad-hoc signature (required for ARM64 macOS binaries and icon rendering)
echo "Ad-hoc signing the application bundle..."
codesign --force --deep --sign - "${APP_DIR}"

if [ "${NO_INSTALL}" -eq 1 ]; then
  echo "Build successful! Created Universal ${APP_DIR} in the current directory (--no-install)."
  exit 0
fi

# Automatically copy to the system Applications folder
echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_DIR}" "/Applications/"

echo "Build successful! Created Universal ${APP_DIR} and installed to /Applications."

# Restart the app if it was running, or open it so the user can test immediately
if pgrep -x "${APP_NAME}" > /dev/null; then
  echo "Detecting running instance of ${APP_NAME}. Restarting..."
  killall "${APP_NAME}" || true
  killall tailcat 2>/dev/null || true
  sleep 0.5
fi
open "/Applications/${APP_NAME}.app"
echo "${APP_NAME} has been launched/restarted."
