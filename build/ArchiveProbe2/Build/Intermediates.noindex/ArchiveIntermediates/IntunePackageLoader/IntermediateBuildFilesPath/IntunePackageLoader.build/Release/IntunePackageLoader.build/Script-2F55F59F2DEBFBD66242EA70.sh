#!/bin/sh
set -euo pipefail
HELPER_LABEL="de.axelspringer.intune.package-loader.mirror-service"
APP_INFO_PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
RESOURCES_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
LAUNCH_SERVICES_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchServices"
mkdir -p "$RESOURCES_DIR" "$LAUNCH_SERVICES_DIR"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string IntuneDownload" "$APP_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Delete :SMPrivilegedExecutables" "$APP_INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SMPrivilegedExecutables dict" "$APP_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :SMPrivilegedExecutables:de.axelspringer.intune.package-loader.mirror-service string identifier \\\"de.axelspringer.intune.package-loader.mirror-service\\\" and anchor apple generic and certificate leaf[subject.OU] = \\\"B8ZGRP93K6\\\"" "$APP_INFO_PLIST"
install -m 644 "$SRCROOT/IntunePackageLoaderApp/Resources/IntuneDownload.icns" "$RESOURCES_DIR/IntuneDownload.icns"
HELPER_SOURCE=""
for candidate in \
  "$BUILT_PRODUCTS_DIR/$HELPER_LABEL" \
  "$BUILT_PRODUCTS_DIR/../UninstalledProducts/$HELPER_LABEL" \
  "$BUILT_PRODUCTS_DIR/../UninstalledProducts/macosx/$HELPER_LABEL"
do
  if [[ -f "$candidate" ]]; then
    HELPER_SOURCE="$candidate"
    break
  fi
done
if [[ -z "$HELPER_SOURCE" ]]; then
  HELPER_SOURCE="$(find "$(dirname "$BUILT_PRODUCTS_DIR")" -type f -name "$HELPER_LABEL" | head -n 1 || true)"
fi
if [[ -z "$HELPER_SOURCE" || ! -f "$HELPER_SOURCE" ]]; then
  echo "Could not locate helper binary $HELPER_LABEL" >&2
  exit 1
fi
install -m 755 "$HELPER_SOURCE" "$LAUNCH_SERVICES_DIR/$HELPER_LABEL"
rm -rf "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
rm -f "$RESOURCES_DIR/IntunePackageMirrorService" "$RESOURCES_DIR/$HELPER_LABEL"

