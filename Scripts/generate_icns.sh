#!/bin/bash
set -e

INPUT_IMAGE="Resources/UserIcon.png"
ICONSET_DIR="Resources/AppIcon.iconset"
OUTPUT_ICNS="Resources/AppIcon.icns"

echo "Creating iconset directory..."
mkdir -p "${ICONSET_DIR}"

echo "Generating PNG sizes with sips..."
sips -s format png -z 16 16     "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_16x16.png"
sips -s format png -z 32 32     "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_16x16@2x.png"
sips -s format png -z 32 32     "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_32x32.png"
sips -s format png -z 64 64     "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_32x32@2x.png"
sips -s format png -z 128 128   "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_128x128.png"
sips -s format png -z 256 256   "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_128x128@2x.png"
sips -s format png -z 256 256   "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_256x256.png"
sips -s format png -z 512 512   "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_256x256@2x.png"
sips -s format png -z 512 512   "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_512x512.png"
sips -s format png -z 1024 1024 "${INPUT_IMAGE}" --out "${ICONSET_DIR}/icon_512x512@2x.png"

echo "Compiling to AppIcon.icns via iconutil..."
iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICNS}"

echo "Cleaning up temp iconset directory..."
rm -rf "${ICONSET_DIR}"

echo "Success! Resources/AppIcon.icns generated."
