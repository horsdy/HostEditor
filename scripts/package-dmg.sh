#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
zsh scripts/build.sh

app="dist/HostEditor.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
output="dist/HostEditor-${version}-arm64.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/HostEditor-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

ditto "$app" "$stage/HostEditor.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "HostEditor" -srcfolder "$stage" -format UDZO -ov "$output"
hdiutil verify "$output"
printf 'Built %s\n' "$PWD/$output"
