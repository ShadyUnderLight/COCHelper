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
cp "$project_dir/Resources/COCHelperAppIcon.icns" "$app_dir/Contents/Resources/COCHelperAppIcon.icns"

resource_bundle="$bin_dir/COCHelper_COCHelperCore.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    echo "Missing SwiftPM resource bundle: $resource_bundle" >&2
    exit 1
fi
cp -R "$resource_bundle" "$app_dir/"

# Issue #197：COCHelperApp 资源 bundle（PerfFixtures 性能样本，隐藏 seed 运行时加载）。
app_resource_bundle="$bin_dir/COCHelper_COCHelperApp.bundle"
if [[ ! -d "$app_resource_bundle" ]]; then
    echo "Missing SwiftPM resource bundle: $app_resource_bundle" >&2
    exit 1
fi
cp -R "$app_resource_bundle" "$app_dir/"

echo "Built $app_dir"
