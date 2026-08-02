#!/usr/bin/env bash
# 构建 Linux 客户端完整产物：内核 + 特权 helper + Flutter 应用，可选打包 deb。
# 用法: build-linux.sh [--arch x64|arm64] [--version 1.0.1] [--panel-url https://面板域名] [--package]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
app_dir="$root_dir/app"
arch='x64'
version='1.0.1'
panel_url=''
package=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) arch="$2"; shift 2 ;;
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

"$script_dir/fetch-kernel.sh" linux "$arch"
"$script_dir/build-helper.sh" linux "$arch"

cd "$app_dir"
# Flutter 只为宿主架构产出 Linux 产物，arm64 包需在 arm64 机器上构建
flutter build linux --release --build-name "$version" \
    --dart-define="ECYCLOUD_PANEL_URL=$panel_url" \
    --dart-define="ECYCLOUD_VERSION=$version"
cd "$root_dir"

bundle="$app_dir/build/linux/$arch/release/bundle"
if [[ ! -x "$bundle/ECYCloud" ]]; then
    echo "未找到 Flutter 产物：$bundle" >&2
    exit 1
fi

# deb 载荷按目标绝对路径铺好；helper 与内核同目录进 /opt/ecycloud，
# helper 按自身目录定位 sing-box，GUI 路径也固定在这里（verifyGUICaller 只认它）
stage_dir="$root_dir/build/linux/$arch/debroot"
rm -rf "$stage_dir"
mkdir -p "$stage_dir/opt/ecycloud" "$stage_dir/usr/share/applications" "$stage_dir/DEBIAN"

cp -R "$bundle"/. "$stage_dir/opt/ecycloud/"
install -m 0755 "$root_dir/build/deps/linux-$arch/sing-box" "$stage_dir/opt/ecycloud/sing-box"
install -m 0755 "$root_dir/build/deps/linux-$arch/ecycloud-helper" "$stage_dir/opt/ecycloud/ecycloud-helper"
install -m 0644 "$root_dir/build/deps/linux-$arch/LICENSE.sing-box.txt" "$stage_dir/opt/ecycloud/LICENSE.sing-box.txt"
install -m 0644 "$root_dir/LICENSE" "$stage_dir/opt/ecycloud/LICENSE.txt"
install -m 0644 "$script_dir/installer/linux/com.ecycloud.client.desktop" \
    "$stage_dir/usr/share/applications/com.ecycloud.client.desktop"

for size in 16 32 48 64 128 256; do
    icon_dir="$stage_dir/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    install -m 0644 "$script_dir/installer/linux/icons/$size.png" \
        "$icon_dir/com.ecycloud.client.png"
done

echo ""
echo "客户端产物已就绪：$stage_dir/opt/ecycloud"

if [[ "$package" -ne 1 ]]; then
    exit 0
fi

case "$arch" in
    x64) deb_arch='amd64' ;;
    arm64) deb_arch='arm64' ;;
    *) echo "未知架构 $arch" >&2; exit 1 ;;
esac

sed -e "s/APP_VERSION/$version/" -e "s/APP_ARCH/$deb_arch/" \
    "$script_dir/installer/linux/control" > "$stage_dir/DEBIAN/control"
install -m 0755 "$script_dir/installer/linux/postinst" "$stage_dir/DEBIAN/postinst"
install -m 0755 "$script_dir/installer/linux/prerm" "$stage_dir/DEBIAN/prerm"

out_dir="$root_dir/build/installer"
mkdir -p "$out_dir"
# 构建用户不是 root，--root-owner-group 让载荷统一记为 root:root
dpkg-deb --build --root-owner-group "$stage_dir" \
    "$out_dir/ECYCloud-$version-linux-$arch.deb"

echo "安装器已生成：$out_dir/ECYCloud-$version-linux-$arch.deb"
