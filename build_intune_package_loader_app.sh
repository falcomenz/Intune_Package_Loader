#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"
PROJECT_PATH="$ROOT_DIR/IntunePackageLoader.xcodeproj"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Release/IntunePackageLoader.app"

xcodegen generate --spec "$ROOT_DIR/project.yml"

BUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme IntunePackageLoader
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_DIR"
  build
)

if [[ "${SKIP_CODESIGN:-0}" == "1" ]]; then
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild "${BUILD_ARGS[@]}"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/IntunePackageLoader.app"
cp -R "$APP_PATH" "$DIST_DIR/"

echo "Built: $DIST_DIR/IntunePackageLoader.app"
