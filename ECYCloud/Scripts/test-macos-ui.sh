#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo '用法：bash test-macos-ui.sh <Mac Debug 产品目录> [检查图输出目录]' >&2
    exit 2
fi
products="$1"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /private/tmp/ecycloud-ui-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
export TMPDIR="$test_root/tmp"
export CFFIXED_USER_HOME="$test_root/user"
output="${2:-$test_root/output}"
probe="$test_root/Review.app"
mkdir -p "$CFFIXED_USER_HOME" "$TMPDIR" "$test_root/modules" "$test_root/sources" "$output" "$probe/Contents/MacOS" "$probe/Contents/Resources"
if [[ ! -f "$products/ECYCloudKit.o" || ! -f "$products/ECYCloud.app/Contents/Resources/Assets.car" ]]; then
    echo '缺少 Mac Debug 产品，请先用 xcodebuild 完成 ECYCloud 的 macOS 构建。' >&2
    exit 2
fi
for file in "$project_dir/ECYCloud/"*.swift; do
    case "$(basename "$file")" in ECYCloudApp.swift|AppleStandbyRuntime.swift) continue ;; esac
    cp "$file" "$test_root/sources/"
done
cp "$project_dir/Tests/NativeUIReview/Review.swift" "$test_root/Review.swift"
cp "$project_dir/Tests/NativeUIReview/fixtures.json" "$probe/Contents/Resources/"
cp "$products/ECYCloud.app/Contents/Resources/Assets.car" "$probe/Contents/Resources/"
cp -R "$products/ECYCloudKit_ECYCloudKit.bundle" "$probe/Contents/Resources/"
plutil -create xml1 "$probe/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.ecycloud.native.offline-review "$probe/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Review "$probe/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$probe/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.1.1 "$probe/Contents/Info.plist"
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" -module-cache-path "$test_root/modules" \
    -I "$products" "$products/ECYCloudKit.o" -lxml2 "$test_root/sources/"*.swift \
    "$test_root/Review.swift" -o "$probe/Contents/MacOS/Review"
"$probe/Contents/MacOS/Review" "$output"
