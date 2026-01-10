#!/usr/bin/env bash

# Build a distribution PKG using pkgbuild.
# Usage: ./packaging/create_pkg.sh [/path/to/Dictant.app] [Dictant.pkg] [identifier] [version]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP_PATH="${2:-"$ROOT/build/DerivedData/Build/Products/Release/Dictant.app"}"
PKG_NAME="${3:-DictantInstaller.pkg}"
IDENTIFIER="${4:-ilin.pt.Dictant}"

PKG_PATH="$ROOT/build/$PKG_NAME"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$ROOT/build"
rm -f "$PKG_PATH"

echo "Creating package (using pkgbuild) at $PKG_PATH..."

# Use pkgbuild to package the component
pkgbuild \
  --component "$APP_PATH" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/Applications" \
  "$PKG_PATH"

echo "PKG created at: $PKG_PATH"
