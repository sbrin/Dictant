#!/usr/bin/env bash

# Build the app with xcodebuild and package it into a DMG via create_dmg.sh.
# Usage:
#   ./packaging/build_and_dmg.sh            # uses defaults
#   DERIVED_DATA=custom/DD ./packaging/build_and_dmg.sh
#   DMG_NAME=Custom.dmg ./packaging/build_and_dmg.sh
#   ARCHS="arm64 x86_64" ./packaging/build_and_dmg.sh  # override architectures/destination if needed

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-"$ROOT/Dictant.xcodeproj"}"
SCHEME="${SCHEME:-Dictant}"
DERIVED_DATA="${DERIVED_DATA:-"$ROOT/build/DerivedData"}"
DMG_NAME="${DMG_NAME:-Dictant.dmg}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
ARCHS="${ARCHS:-arm64 x86_64}"
ONLY_ACTIVE_ARCH="${ONLY_ACTIVE_ARCH:-NO}"

APP_PATH="$DERIVED_DATA/Build/Products/Release/Dictant.app"

echo "Building Release app..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "$DESTINATION" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

echo "Packaging DMG..."
"$ROOT/packaging/create_dmg.sh" "$APP_PATH" "$DMG_NAME"
