#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
identity="${SIGNING_IDENTITY:--}"
swift build -c "$configuration" --arch arm64 --scratch-path .build
binary_dir="$(swift build -c "$configuration" --arch arm64 --scratch-path .build --show-bin-path)"
app="dist/HostEditor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/HelperTools" "$app/Contents/Library/LaunchDaemons" "$app/Contents/Resources"
swift scripts/generate-icon.swift .build
iconutil -c icns .build/HostEditor.iconset -o "$app/Contents/Resources/HostEditor.icns"
cp .build/HostEditor.png "$app/Contents/Resources/HostEditor.png"
cp "$binary_dir/HostEditor" "$app/Contents/MacOS/HostEditor"
cp "$binary_dir/HostEditorHelper" "$app/Contents/Library/HelperTools/HostEditorHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/com.hosteditor.app.helper.plist "$app/Contents/Library/LaunchDaemons/"
timestamp_flag="--timestamp"
if [[ "$identity" == "-" ]]; then timestamp_flag="--timestamp=none"; fi
codesign --force --options runtime "$timestamp_flag" --sign "$identity" --identifier com.hosteditor.app.helper "$app/Contents/Library/HelperTools/HostEditorHelper"
codesign --force --options runtime "$timestamp_flag" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$PWD/$app"
if [[ "$identity" == "-" ]]; then
    printf 'Development build: protected writes use macOS administrator authentication.\n'
fi
