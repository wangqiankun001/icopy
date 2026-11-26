#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="icopy"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ARCH="$(uname -m)"

echo "Building $APP_NAME for ${ARCH}..."

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
  -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macosx13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -framework Cocoa \
  -framework Carbon \
  -framework ApplicationServices \
  -framework ServiceManagement

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "Generating app icon…"
  swift Tools/make_icon.swift
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
