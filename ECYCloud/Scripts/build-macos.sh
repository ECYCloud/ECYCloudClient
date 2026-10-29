#!/bin/bash
# 正式签名与公证沿用 scripts/build-macos.sh 的变量：ECYCLOUD_MACOS_SIGN_IDENTITY 与 ECYCLOUD_MACOS_INSTALLER_IDENTITY 须同时设置，
# ECYCLOUD_MACOS_NOTARY_KEY / _KEY_ID / _ISSUER 可选；都不设时沿用工程的开发签名出包
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
root_dir="$(dirname "$project_dir")"
version='' build='' arch='' channel=last
output="$root_dir/build/installer"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --build) build="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo '必须指定 --version X.Y.Z 和 --build 构建号' >&2; exit 2; }
case "$channel" in
    last) display_version="$version" ;;
    pre) display_version="Pre $version" ;;
    *) echo '通道只能是 --channel last 或 pre' >&2; exit 2 ;;
esac
case "$arch" in
    arm64) targets=arm64; architectures=arm64; hosts=arm64 ;;
    x64) targets=x64; architectures=x86_64; hosts=x86_64 ;;
    universal) targets='arm64 x64'; architectures='arm64 x86_64'; hosts='arm64,x86_64' ;;
    *) echo '必须指定 --arch arm64、x64 或 universal' >&2; exit 2 ;;
esac
: "${TMPDIR:?请显式指定编译临时目录 TMPDIR}"
mkdir -p "$TMPDIR" "$output"
output="$(cd "$output" && pwd)"
# 文件名不带构建号：安装包目录只保留这一个最新包，构建号只写进包内元数据
package="$output/ECYCloud-$version-macos-$arch-native.pkg"
sign_identity="${ECYCLOUD_MACOS_SIGN_IDENTITY:-}"
installer_identity="${ECYCLOUD_MACOS_INSTALLER_IDENTITY:-}"
[[ -z "$sign_identity" && -z "$installer_identity" || -n "$sign_identity" && -n "$installer_identity" ]] || { echo '应用与安装包签名身份必须同时设置' >&2; exit 2; }
sign_name='' team=''
if [[ -n "$sign_identity" ]]; then
    # 身份可写名称或 SHA-1；钥匙串里有同名证书时 codesign 只认 SHA-1
    line="$(security find-identity -v -p codesigning | grep -F -- "$sign_identity" | grep -F '"Developer ID Application:' | head -n 1 || true)"
    [[ "$line" =~ \"(Developer\ ID\ Application:.*\(([A-Z0-9]{10})\))\"$ ]] || { echo "钥匙串中没有 Developer ID Application 身份：$sign_identity" >&2; exit 2; }
    sign_name="${BASH_REMATCH[1]}" team="${BASH_REMATCH[2]}"
fi
work="$(mktemp -d "${TMPDIR%/}/ecycloud-native-package.XXXXXX")"
staged="$work/out/$(basename "$package")"
trap 'chmod -R u+w -- "$work" 2>/dev/null || true; rm -rf -- "$work"' EXIT
export TMPDIR="$work/tmp" CFFIXED_USER_HOME="$work" XDG_CACHE_HOME="$work/cache"
export CLANG_MODULE_CACHE_PATH="$work/modules" SWIFTPM_MODULECACHE_OVERRIDE="$work/modules"
export ECYCLOUD_BUILD_DIR="${ECYCLOUD_BUILD_DIR:-$work/build}"
export GOCACHE="${GOCACHE:-$work/go-cache}" GOPATH="${GOPATH:-$work/go-work}" GOTMPDIR="$TMPDIR"
mkdir -p "$TMPDIR" "$work/Library/Developer/Xcode/UserData/Provisioning Profiles"
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
if [[ -d "$profiles" ]]; then
    for profile in "$profiles"/*.provisionprofile; do
        [[ ! -f "$profile" ]] || cp "$profile" "$work/Library/Developer/Xcode/UserData/Provisioning Profiles/"
    done
fi
for target in $targets; do
    bash "$root_dir/scripts/fetch-kernel.sh" macos "$target"
    bash "$root_dir/scripts/build-helper.sh" macos "$target"
done
kernel_version="$(jq -er '.mihomo.version' "$root_dir/scripts/kernel.lock.json")"
# Developer ID 签名先归档再按 developer-id 导出：keychain-access-groups 需要 Developer ID 描述文件，由 Xcode 账号
# 或公证用的 App Store Connect 密钥自动取得；导出须读取真实用户目录下的 Xcode 账号，不能沿用隔离的 CFFIXED_USER_HOME
provisioning=()
if [[ -n "${ECYCLOUD_MACOS_NOTARY_KEY:-}" ]]; then
    provisioning=(-authenticationKeyPath "$ECYCLOUD_MACOS_NOTARY_KEY"
        -authenticationKeyID "${ECYCLOUD_MACOS_NOTARY_KEY_ID:?缺少 ECYCLOUD_MACOS_NOTARY_KEY_ID}"
        -authenticationKeyIssuerID "${ECYCLOUD_MACOS_NOTARY_ISSUER:?缺少 ECYCLOUD_MACOS_NOTARY_ISSUER}")
fi
action=(build)
[[ -z "$sign_identity" ]] || action=(archive -archivePath "$work/ECYCloud.xcarchive")
xcodebuild -project "$project_dir/ECYCloud.xcodeproj" -scheme ECYCloud -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" \
    -clonedSourcePackagesDirPath "$work/SourcePackages" -disableAutomaticPackageResolution \
    "ARCHS=$architectures" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES ENABLE_DEBUG_DYLIB=NO \
    ECY_KERNEL_VERSION="$kernel_version" SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    ECY_DISPLAY_VERSION="$display_version" \
    COMPILER_INDEX_STORE_ENABLE=NO REGISTER_APP_WITH_LAUNCH_SERVICES=NO \
    CLANG_MODULE_CACHE_PATH="$work/modules" SWIFT_MODULECACHE_PATH="$work/modules" "${action[@]}"
app="$work/DerivedData/Build/Products/Release/ECYCloud.app"
if [[ -n "$sign_identity" ]]; then
    cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$team</string>
<key>destination</key><string>export</string>
</dict></plist>
PLIST
    env -u CFFIXED_USER_HOME xcodebuild -exportArchive -archivePath "$work/ECYCloud.xcarchive" -exportPath "$work/export" \
        -exportOptionsPlist "$work/export.plist" -allowProvisioningUpdates ${provisioning[@]+"${provisioning[@]}"}
    app="$work/export/ECYCloud.app"
    codesign --display --verbose=2 "$app" 2>&1 | grep -xF "Authority=$sign_name" > /dev/null || { echo "导出的应用未使用 $sign_name 签名" >&2; exit 1; }
fi
for pair in "ECYDisplayVersion=$display_version" "ECYKernelVersion=$kernel_version"; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :${pair%%=*}" "$app/Contents/Info.plist" 2>/dev/null)" == "${pair#*=}" ]] || { echo "应用 Info.plist 缺少 ${pair%%=*}" >&2; exit 1; }
done
codesign --verify --deep --strict "$app"
codesign --display --entitlements - --xml "$app" > "$work/entitlements.plist"
for permission in com.apple.security.app-sandbox com.apple.security.get-task-allow com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-dyld-environment-variables; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$permission" "$work/entitlements.plist" 2>/dev/null || true)"
    [[ "$value" != true ]] || { echo "不允许的发行权限：$permission" >&2; exit 1; }
done
stage="$work/pkgroot"
bin="$stage/Library/Application Support/ECYCloud/bin"
mkdir -p "$stage/Applications" "$bin" "$work/scripts" "$work/resources"
ditto --norsrc --noextattr "$app" "$stage/Applications/ECYCloud.app"
for name in mihomo ecycloud-helper; do
    inputs=()
    for target in $targets; do inputs+=("$ECYCLOUD_BUILD_DIR/deps/macos-$target/$name"); done
    if [[ "$arch" == universal ]]; then lipo -create "${inputs[@]}" -output "$bin/$name"
    else cp "${inputs[0]}" "$bin/$name"; fi
    chmod 0755 "$bin/$name"
    # 公证逐个检查载荷里的 Mach-O，包外的 helper 与内核也要 Developer ID、加固运行时与时间戳
    if [[ -n "$sign_identity" ]]; then
        codesign --force --options runtime --timestamp --sign "$sign_identity" "$bin/$name"
        codesign --verify --strict "$bin/$name"
    fi
done
first="${targets%% *}"
for name in LICENSE.mihomo.txt geoip.metadb GeoSite.dat; do
    install -m 0644 "$ECYCLOUD_BUILD_DIR/deps/macos-$first/$name" "$bin/$name"
done
for name in preinstall postinstall; do install -m 0755 "$root_dir/scripts/installer/macos/scripts/$name" "$work/scripts/$name"; done
for language in English zh_CN zh_TW; do mkdir -p "$work/resources/$language.lproj"; done
install -m 0644 "$root_dir/LICENSE" "$work/resources/English.lproj/LICENSE.txt"
install -m 0644 "$root_dir/scripts/installer/lang/LICENSE.zh-CN.txt" "$work/resources/zh_CN.lproj/LICENSE.txt"
install -m 0644 "$root_dir/scripts/installer/lang/LICENSE.zh-TW.txt" "$work/resources/zh_TW.lproj/LICENSE.txt"
sed -e "s/APP_VERSION/$version.$build/g" -e "s/HOST_ARCHITECTURES/$hosts/g" -e 's/min="11.0"/min="14.0"/' \
    "$root_dir/scripts/installer/macos/distribution.xml" > "$work/distribution.xml"
pkgbuild --analyze --root "$stage" "$work/components.plist"
plutil -replace 0.BundleIsRelocatable -bool false "$work/components.plist"
pkgbuild --root "$stage" --install-location / --identifier com.ecycloud.client --version "$version.$build" \
    --ownership recommended --component-plist "$work/components.plist" --scripts "$work/scripts" "$work/component.pkg"
product=(--distribution "$work/distribution.xml" --package-path "$work" --resources "$work/resources")
[[ -z "$installer_identity" ]] || product+=(--sign "$installer_identity" --timestamp)
mkdir -p "$work/out"
productbuild "${product[@]}" "$staged"
if [[ -n "${ECYCLOUD_MACOS_NOTARY_KEY:-}" ]]; then
    notary=(--key "$ECYCLOUD_MACOS_NOTARY_KEY" --key-id "$ECYCLOUD_MACOS_NOTARY_KEY_ID" --issuer "$ECYCLOUD_MACOS_NOTARY_ISSUER")
    result="$(xcrun notarytool submit "$staged" "${notary[@]}" --wait --output-format json)"
    # --wait 只等处理结束，Invalid 也可能正常返回，必须看 status
    if [[ "$(jq -r '.status' <<< "$result")" != Accepted ]]; then
        echo "公证未通过：$result" >&2
        xcrun notarytool log "$(jq -r '.id' <<< "$result")" "${notary[@]}" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$staged"
    xcrun stapler validate "$staged"
    spctl --assess --type install --verbose "$staged"
fi
# 全部成功才覆盖现有包；同平台同架构的其它原生安装包（含旧的带构建号文件）一并删除
mv -f "$staged" "$package"
find "$output" -maxdepth 1 -name "ECYCloud-*-macos-$arch-native.pkg" ! -name "$(basename "$package")" -delete
echo "已生成包含 mihomo、helper 和 geodata 的原生安装包：$package"
