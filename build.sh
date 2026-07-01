#!/bin/bash
set -e

# Define directories
APP_NAME="MacHead"
APP_DIR="${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"

echo "Building MacHead..."

# Clean previous build
if [ -d "${APP_DIR}" ]; then
  rm -rf "${APP_DIR}"
fi

# Create directory structure
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Compile Swift files
# Using the active SDK and target the current system architecture
SDK_PATH=$(xcrun --show-sdk-path)
echo "Using SDK: ${SDK_PATH}"

swiftc \
  -sdk "${SDK_PATH}" \
  -O \
  -o "${MACOS_DIR}/${APP_NAME}" \
  -framework SwiftUI \
  -framework Cocoa \
  -framework IOKit \
  -framework CoreGraphics \
  -framework CoreAudio \
  MacHeadApp.swift \
  AppDelegate.swift \
  DisplayManager.swift \
  HeadlessModeController.swift \
  LaunchAtLoginHelper.swift \
  PreferencesView.swift \
  InputDeviceManager.swift \
  BatteryManager.swift \
  MediaDeviceManager.swift \
  main.swift \
  WebServer.swift

# Copy Info.plist to the bundle
cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Copy AppIcon to resources
mkdir -p "${APP_DIR}/Contents/Resources"
cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Automatically copy to the system Applications folder
echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_DIR}" "/Applications/"

echo "Build successful! Created ${APP_DIR} and installed to /Applications."
