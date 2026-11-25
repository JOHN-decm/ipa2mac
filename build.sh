#!/bin/bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")" && pwd)
dist_dir="$root_dir/dist"
app_name="IPA装到Mac"

mkdir -p "$dist_dir"
work_dir=$(mktemp -d "$dist_dir/.build.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

app_path="$work_dir/$app_name.app"
zip_path="$work_dir/$app_name.zip"

osacompile -o "$app_path" "$root_dir/app/main.applescript"
# osacompile 默认允许拖入任意文件。沿用原 App 的 IPA 文件关联。
plutil -replace CFBundleDocumentTypes -json \
  '[{"CFBundleTypeExtensions":["ipa"],"CFBundleTypeRole":"Viewer","LSItemContentTypes":["public.data"]}]' \
  "$app_path/Contents/Info.plist"
install -m 755 "$root_dir/ipa2mac.sh" "$app_path/Contents/Resources/ipa2mac.sh"

codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --strict "$app_path"
ditto -c -k --keepParent "$app_path" "$zip_path"

rm -rf "$dist_dir/$app_name.app"
mv "$app_path" "$zip_path" "$dist_dir/"
printf '已构建\n  %s\n  %s\n' "dist/$app_name.app" "dist/$app_name.zip"
