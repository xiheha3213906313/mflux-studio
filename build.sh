#!/bin/zsh
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
app="$project_dir/build/MFlux Studio.app"
contents="$app/Contents"
resources="$contents/Resources"

mkdir -p "$contents/MacOS" "$resources/zh-Hans.lproj"
cp "$project_dir/Resources/Info.plist" "$contents/Info.plist"
cp "$project_dir/Resources/DownloadPreset.py" "$resources/DownloadPreset.py"
cp "$project_dir/Resources/zh-Hans.lproj/InfoPlist.strings" "$resources/zh-Hans.lproj/InfoPlist.strings"

xcrun swiftc -O -target arm64-apple-macos14.0 \
    "$project_dir/Sources/MFluxStudio.swift" \
    "$project_dir/Sources/StudioModels.swift" \
    "$project_dir/Sources/StudioViews.swift" \
    "$project_dir/Sources/StudioImaging.swift" \
    -o "$contents/MacOS/MFluxStudio"
codesign --force --sign - "$app"
printf '%s\n' "$app"
