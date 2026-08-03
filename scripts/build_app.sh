#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}/.."
cd "$project_dir"

swift build -c release
bin_dir="$(swift build --show-bin-path -c release)"
app_dir="$project_dir/.build/COCHelper.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/COCHelper" "$app_dir/Contents/MacOS/COCHelper"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

echo "Built $app_dir"
