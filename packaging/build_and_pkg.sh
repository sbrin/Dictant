#!/usr/bin/env bash

# Build the app with xcodebuild and package it into a PKG via create_pkg.sh.
# Usage:
#   ./packaging/build_and_pkg.sh            # uses defaults
#   DERIVED_DATA=custom/DD ./packaging/build_and_pkg.sh
#   PKG_NAME=Custom.pkg ./packaging/build_and_pkg.sh
#   VERSION=1.2.3 ./packaging/build_and_pkg.sh
#   ARCHS="arm64 x86_64" ./packaging/build_and_pkg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-"$ROOT/Dictant.xcodeproj"}"
SCHEME="${SCHEME:-Dictant}"
DERIVED_DATA="${DERIVED_DATA:-"$ROOT/build/DerivedData"}"
PKG_NAME="${PKG_NAME:-DictantInstaller.pkg}"
IDENTIFIER="${IDENTIFIER:-ilin.pt.Dictant}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
ARCHS="${ARCHS:-arm64 x86_64}"
ONLY_ACTIVE_ARCH="${ONLY_ACTIVE_ARCH:-NO}"
VERSION="${VERSION:-1.0.0}"

ARCHIVE_PATH="$ROOT/build/Dictant.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/Dictant.app"

build_settings=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null || true)
current_build=$(echo "$build_settings" | awk '/CURRENT_PROJECT_VERSION/ {print $3; exit}')
current_marketing=$(echo "$build_settings" | awk '/MARKETING_VERSION/ {print $3; exit}')

if [[ -n "${VERSION:-}" ]]; then
  marketing_version="$VERSION"
else
  marketing_version="$current_marketing"
fi

if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then
  next_build="$CURRENT_PROJECT_VERSION"
else
  if [[ "$current_build" =~ ^[0-9]+$ ]]; then
    next_build=$((current_build + 1))
  else
    next_build=1
  fi
fi

echo "Archiving Release app..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "$DESTINATION" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$next_build" \
  archive

echo "Packaging PKG..."
"$ROOT/packaging/create_pkg.sh" "$APP_PATH" "$PKG_NAME" "$IDENTIFIER" "$VERSION"
