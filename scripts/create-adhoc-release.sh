#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
output_directory="${1:-$project_root/build/release}"
archive_path="$output_directory/QuickRecorder.xcarchive"
app_path="$archive_path/Products/Applications/QuickRecorder.app"

mkdir -p "$output_directory"

xcodebuild \
    -project "$project_root/QuickRecorder.xcodeproj" \
    -scheme QuickRecorder \
    -configuration Release \
    -archivePath "$archive_path" \
    archive

# Ad-hoc signing gives TCC a stable application identity, but does not replace
# Developer ID signing or notarization for public distribution.
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
dmg_path="$output_directory/QuickRecorder_v${version}.dmg"

hdiutil create \
    -volname "QuickRecorder $version" \
    -srcfolder "$app_path" \
    -ov \
    -format UDZO \
    "$dmg_path"
hdiutil verify "$dmg_path"
shasum -a 256 "$dmg_path"

echo "Created $dmg_path"
echo "Warning: this build is ad-hoc signed and not notarized."
