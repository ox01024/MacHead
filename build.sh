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
  -target arm64-apple-macos13.0 \
  -sdk "${SDK_PATH}" \
  -O \
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
  -target x86_64-apple-macos13.0 \
  -sdk "${SDK_PATH}" \
  -O \
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

# Copy AppIcon to resources
mkdir -p "${APP_DIR}/Contents/Resources"
cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Automatically copy to the system Applications folder
echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_DIR}" "/Applications/"

echo "Build successful! Created Universal ${APP_DIR} and installed to /Applications."
