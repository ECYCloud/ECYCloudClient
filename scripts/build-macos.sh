#!/usr/bin/env bash
# 构建 macOS 客户端完整产物：内核 + 特权 helper + Flutter 应用，可选打包 pkg。
# 用法: build-macos.sh --arch x64|arm64 [--version 1.0.1] [--channel last|pre] [--panel-url https://站点域名] [--sub-url https://订阅域名] [--package] [--from-stage]
# --from-stage 跳过构建，只签名并打包已有的 build/macos/<arch>/pkgroot（CI 签名作业用，不运行任何依赖代码）
# 正式签名与公证（均可选，见 docs/macos.md）：ECYCLOUD_MACOS_SIGN_IDENTITY、ECYCLOUD_MACOS_INSTALLER_IDENTITY、
# ECYCLOUD_MACOS_NOTARY_KEY / ECYCLOUD_MACOS_NOTARY_KEY_ID / ECYCLOUD_MACOS_NOTARY_ISSUER
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
app_dir="$root_dir/app"
arch=''
version='1.0.1'
channel='last'
panel_url=''
sub_url=''
package=0
from_stage=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) arch="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --panel-url) panel_url="$2"; shift 2 ;;
        --sub-url) sub_url="$2"; shift 2 ;;
        --package) package=1; shift ;;
        --from-stage) from_stage=1; shift ;;
        *) echo "未知参数 $1" >&2; exit 1 ;;
    esac
done

case "$arch" in
    x64)
        darwin_arch='x86_64'
        host_architectures='x86_64'
        ;;
    arm64)
        darwin_arch='arm64'
        host_architectures='arm64'
        ;;
    *)
        echo "必须指定 --arch x64 或 arm64" >&2
        exit 1
        ;;
esac

# CFBundleShortVersionString 与产物名只收纯号段，Pre 前缀只进界面展示串
case "$channel" in
    last) display_version="$version" ;;
    pre) display_version="Pre $version" ;;
    *) echo "未知通道 $channel，只能是 last 或 pre" >&2; exit 1 ;;
esac

if [[ -z "$panel_url" ]]; then
    panel_url="$(jq -er '.panelUrl' "$root_dir/config/panel.json")"
fi
if [[ -z "$sub_url" ]]; then
    sub_url="$(jq -er '.subUrl' "$root_dir/config/panel.json")"
fi
if [[ ! "$panel_url" =~ ^https:// ]]; then
    echo "站点域名必须是 https 地址：$panel_url" >&2
    exit 1
fi
if [[ ! "$sub_url" =~ ^https:// ]]; then
    echo "订阅域名必须是 https 地址：$sub_url" >&2
    exit 1
fi

# helper 与内核同目录，helper 按自身目录定位 mihomo
stage_dir="$root_dir/build/macos/$arch/pkgroot"
bin_dir="$stage_dir/Library/Application Support/ECYCloud/bin"

if [[ "$from_stage" -eq 1 ]]; then
    bundle="$stage_dir/Applications/ECYCloud.app"
    if [[ ! -d "$bundle" || ! -f "$bin_dir/ecycloud-helper" || ! -f "$bin_dir/mihomo" ]]; then
        echo "未找到待签名的组装产物：$stage_dir" >&2
        exit 1
    fi
else
    "$script_dir/fetch-kernel.sh" macos "$arch"
    "$script_dir/build-helper.sh" macos "$arch"

    deps_dir="$root_dir/build/deps/macos-$arch"

    cd "$app_dir"
    # Release 默认真通用二进制；先整包编出再 thin 到目标架构，避免依赖尚未稳定的 --darwin-arch
    flutter build macos --release --build-name "$version" \
        --dart-define="ECYCLOUD_SITE_URL=$panel_url" \
        --dart-define="ECYCLOUD_SUB_URL=$sub_url" \
        --dart-define="ECYCLOUD_VERSION=$display_version"
    cd "$root_dir"

    bundle="$app_dir/build/macos/Build/Products/Release/ECYCloud.app"
    if [[ ! -d "$bundle" ]]; then
        echo "未找到 Flutter 产物：$bundle" >&2
        exit 1
    fi

    while IFS= read -r -d '' file; do
        if ! file -b "$file" | grep -q 'Mach-O'; then
            continue
        fi
        info="$(lipo -info "$file" 2>/dev/null || true)"
        if [[ -z "$info" ]]; then
            continue
        fi
        if [[ "$info" == *"Architectures in the fat file"* ]]; then
            lipo -thin "$darwin_arch" "$file" -output "$file.thin"
            mv "$file.thin" "$file"
            continue
        fi
        if [[ "$info" != *"$darwin_arch"* ]]; then
            echo "产物架构不是 $darwin_arch：$file ($info)" >&2
            exit 1
        fi
    done < <(find "$bundle" -type f -print0)
fi

# lipo 瘦身改写了 Mach-O，使编译期签名失效；瘦身后必须重新签名并启用加固运行时（--options runtime），
# 否则加固运行时不生效、DYLD_INSERT_LIBRARIES 注入官方 GUI 驱动特权 helper 的提权路径挡不住（见 docs/macos.md）。
# 默认 ad-hoc（-）即可让 dyld 强制加固运行时；设 ECYCLOUD_MACOS_SIGN_IDENTITY 走 Developer ID 正式签名。
sign_identity="${ECYCLOUD_MACOS_SIGN_IDENTITY:--}"
entitlements="$app_dir/macos/Runner/Release.entitlements"
sign_opts=(--force --options runtime --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_opts+=(--timestamp)
    # 关库校验只为放行 ad-hoc 的嵌套框架；全部换成同一 Developer ID 后恢复
    entitlements="$root_dir/build/macos/$arch/Release.entitlements"
    mkdir -p "$(dirname "$entitlements")"
    cp "$app_dir/macos/Runner/Release.entitlements" "$entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.cs.disable-library-validation' "$entitlements"
fi
# --deep 不可靠地覆盖嵌套代码，须由内向外逐个签：先散落的 Mach-O，再嵌套 bundle，最后外层 .app
while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then
        codesign "${sign_opts[@]}" "$file"
    fi
done < <(find "$bundle/Contents" -type f ! -path "$bundle/Contents/MacOS/ECYCloud" -print0)
while IFS= read -r -d '' nested; do
    codesign "${sign_opts[@]}" "$nested"
done < <(find "$bundle/Contents" -depth -type d \( -name '*.framework' -o -name '*.app' \
    -o -name '*.appex' -o -name '*.xpc' -o -name '*.bundle' \) -print0)
codesign "${sign_opts[@]}" --entitlements "$entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"

if [[ "$from_stage" -eq 0 ]]; then
    rm -rf "$stage_dir"
    mkdir -p "$stage_dir/Applications" "$bin_dir"
    cp -R "$bundle" "$stage_dir/Applications/"
    # 逐个点名：deps 是增量的，换内核后旧文件还在
    install -m 0755 "$deps_dir/mihomo" "$bin_dir/mihomo"
    install -m 0755 "$deps_dir/ecycloud-helper" "$bin_dir/ecycloud-helper"
    install -m 0644 "$deps_dir/LICENSE.mihomo.txt" "$bin_dir/LICENSE.mihomo.txt"
    # geodata 与内核同目录：缺了内核会按 geox-url 同步下载，面板地址在目标网络不可达
    install -m 0644 "$deps_dir/geoip.metadb" "$bin_dir/geoip.metadb"
    install -m 0644 "$deps_dir/GeoSite.dat" "$bin_dir/GeoSite.dat"
fi
# 公证逐个检查载荷里的 Mach-O，包外的 helper 与内核也要 Developer ID + 加固运行时 + 时间戳
if [[ "$sign_identity" != "-" ]]; then
    codesign "${sign_opts[@]}" "$bin_dir/ecycloud-helper" "$bin_dir/mihomo"
    codesign --verify --strict "$bin_dir/ecycloud-helper" "$bin_dir/mihomo"
fi

echo ""
echo "客户端产物已就绪：$stage_dir"

if [[ "$package" -ne 1 ]]; then
    exit 0
fi

out_dir="$root_dir/build/installer"
work_dir="$root_dir/build/macos/$arch/pkg"
rm -rf "$work_dir"
mkdir -p "$work_dir/resources" "$work_dir/scripts" "$out_dir"

# 根目录不能放 LICENSE.txt，否则语言菜单换了正文仍是英文；PKG 只认 English / zh_CN / zh_TW
mkdir -p \
    "$work_dir/resources/English.lproj" \
    "$work_dir/resources/zh_CN.lproj" \
    "$work_dir/resources/zh_TW.lproj"
install -m 0644 "$root_dir/LICENSE" "$work_dir/resources/English.lproj/LICENSE.txt"
install -m 0644 "$script_dir/installer/lang/LICENSE.zh-CN.txt" \
    "$work_dir/resources/zh_CN.lproj/LICENSE.txt"
install -m 0644 "$script_dir/installer/lang/LICENSE.zh-TW.txt" \
    "$work_dir/resources/zh_TW.lproj/LICENSE.txt"
sed -e "s/APP_VERSION/$version/" \
    -e "s/HOST_ARCHITECTURES/$host_architectures/" \
    "$script_dir/installer/macos/distribution.xml" \
    > "$work_dir/distribution.xml"
# pkgbuild 要求脚本可执行，仓库里的文件模式不可依赖
install -m 0755 "$script_dir/installer/macos/scripts/preinstall" "$work_dir/scripts/preinstall"
install -m 0755 "$script_dir/installer/macos/scripts/postinstall" "$work_dir/scripts/postinstall"

# 载荷由非 root 构建，ownership recommended 让安装时统一落成 root:wheel
pkgbuild --root "$stage_dir" \
    --install-location / \
    --identifier com.ecycloud.client \
    --version "$version" \
    --ownership recommended \
    --scripts "$work_dir/scripts" \
    "$work_dir/component.pkg"

pkg_name="ECYCloud-$version-macos-$arch.pkg"
pkg_path="$out_dir/$pkg_name"
product_opts=(--distribution "$work_dir/distribution.xml"
    --package-path "$work_dir"
    --resources "$work_dir/resources")
if [[ -n "${ECYCLOUD_MACOS_INSTALLER_IDENTITY:-}" ]]; then
    product_opts+=(--sign "$ECYCLOUD_MACOS_INSTALLER_IDENTITY" --timestamp)
fi
productbuild "${product_opts[@]}" "$pkg_path"

if [[ -n "${ECYCLOUD_MACOS_NOTARY_KEY:-}" ]]; then
    notary_auth=(--key "$ECYCLOUD_MACOS_NOTARY_KEY"
        --key-id "${ECYCLOUD_MACOS_NOTARY_KEY_ID:?缺少 ECYCLOUD_MACOS_NOTARY_KEY_ID}"
        --issuer "${ECYCLOUD_MACOS_NOTARY_ISSUER:?缺少 ECYCLOUD_MACOS_NOTARY_ISSUER}")
    result="$(xcrun notarytool submit "$pkg_path" "${notary_auth[@]}" --wait --output-format json)"
    # --wait 只等处理结束，Invalid 也可能正常返回，必须看 status
    if [[ "$(jq -r '.status' <<< "$result")" != Accepted ]]; then
        echo "公证未通过：$result" >&2
        xcrun notarytool log "$(jq -r '.id' <<< "$result")" "${notary_auth[@]}" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$pkg_path"
    xcrun stapler validate "$pkg_path"
    spctl --assess --type install --verbose "$pkg_path"
fi

echo "安装器已生成：$pkg_path"
