#!/usr/bin/env bash
# 构建 macOS 客户端完整产物：内核 + 特权 helper + Flutter 应用，可选打包 pkg。
# 用法: build-macos.sh [--version 1.0.1] [--panel-url https://面板域名] [--package]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
app_dir="$root_dir/app"
version='1.0.1'
panel_url=''
package=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --panel-url) panel_url="$2"; shift 2 ;;
        --package) package=1; shift ;;
        *) echo "未知参数 $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$panel_url" ]]; then
    panel_url="$(jq -er '.panelUrl' "$root_dir/config/panel.json")"
fi
if [[ ! "$panel_url" =~ ^https?:// ]]; then
    echo "面板地址不是合法的 http(s) 地址：$panel_url" >&2
    exit 1
fi

# Flutter 的 macOS 发布产物是通用二进制，随包的内核与 helper 也要合成通用二进制
for arch in x64 arm64; do
    "$script_dir/fetch-kernel.sh" macos "$arch"
    "$script_dir/build-helper.sh" macos "$arch"
done

deps_dir="$root_dir/build/deps/macos-universal"
rm -rf "$deps_dir"
mkdir -p "$deps_dir"
for binary in sing-box ecycloud-helper; do
    lipo -create \
        "$root_dir/build/deps/macos-x64/$binary" \
        "$root_dir/build/deps/macos-arm64/$binary" \
        -output "$deps_dir/$binary"
    chmod 0755 "$deps_dir/$binary"
done
install -m 0644 "$root_dir/build/deps/macos-arm64/LICENSE.sing-box.txt" "$deps_dir/LICENSE.sing-box.txt"

cd "$app_dir"
flutter build macos --release --build-name "$version" \
    --dart-define="ECYCLOUD_PANEL_URL=$panel_url" \
    --dart-define="ECYCLOUD_VERSION=$version"
cd "$root_dir"

bundle="$app_dir/build/macos/Build/Products/Release/ECYCloud.app"
if [[ ! -d "$bundle" ]]; then
    echo "未找到 Flutter 产物：$bundle" >&2
    exit 1
fi

# pkg 载荷按目标绝对路径铺好，两块内容一次装：GUI 进 /Applications，
# helper 与内核同目录进 /Library/Application Support，helper 按自身目录定位 sing-box
stage_dir="$root_dir/build/macos/pkgroot"
rm -rf "$stage_dir"
mkdir -p "$stage_dir/Applications" "$stage_dir/Library/Application Support/ECYCloud/bin"
cp -R "$bundle" "$stage_dir/Applications/"
cp "$deps_dir"/* "$stage_dir/Library/Application Support/ECYCloud/bin/"

echo ""
echo "客户端产物已就绪：$stage_dir"

if [[ "$package" -ne 1 ]]; then
    exit 0
fi

out_dir="$root_dir/build/installer"
work_dir="$root_dir/build/macos/pkg"
rm -rf "$work_dir"
mkdir -p "$work_dir/resources" "$work_dir/scripts" "$out_dir"

install -m 0644 "$root_dir/LICENSE" "$work_dir/resources/LICENSE.txt"
sed "s/APP_VERSION/$version/" "$script_dir/installer/macos/distribution.xml" \
    > "$work_dir/distribution.xml"
# pkgbuild 要求脚本可执行，仓库里的文件模式不可依赖
install -m 0755 "$script_dir/installer/macos/scripts/postinstall" "$work_dir/scripts/postinstall"

# 载荷由非 root 构建，ownership recommended 让安装时统一落成 root:wheel
pkgbuild --root "$stage_dir" \
    --install-location / \
    --identifier com.ecycloud.client \
    --version "$version" \
    --ownership recommended \
    --scripts "$work_dir/scripts" \
    "$work_dir/component.pkg"

productbuild --distribution "$work_dir/distribution.xml" \
    --package-path "$work_dir" \
    --resources "$work_dir/resources" \
    "$out_dir/ECYCloud-$version-macos.pkg"

echo "安装器已生成：$out_dir/ECYCloud-$version-macos.pkg"
