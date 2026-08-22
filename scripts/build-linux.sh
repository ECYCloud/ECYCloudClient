#!/usr/bin/env bash
# 构建 Linux 客户端完整产物：内核 + 特权 helper + Flutter 应用，可选打包 deb / rpm / tar.gz。
# 用法: build-linux.sh [--arch x64|arm64] [--version 1.0.1] [--channel last|pre] [--panel-url https://站点域名] [--sub-url https://订阅域名] [--package] [--format deb,rpm,tar]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
app_dir="$root_dir/app"
arch='x64'
version='1.0.1'
channel='last'
panel_url=''
sub_url=''
package=0
formats='deb rpm tar'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) arch="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --panel-url) panel_url="$2"; shift 2 ;;
        --sub-url) sub_url="$2"; shift 2 ;;
        --package) package=1; shift ;;
        --format) formats="${2//,/ }"; shift 2 ;;
        *) echo "未知参数 $1" >&2; exit 1 ;;
    esac
done

case "$arch" in
    x64) deb_arch='amd64'; rpm_arch='x86_64' ;;
    arm64) deb_arch='arm64'; rpm_arch='aarch64' ;;
    *) echo "未知架构 $arch" >&2; exit 1 ;;
esac

# deb / rpm 的版本字段与产物名只收纯号段，Pre 前缀只进界面展示串
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
if [[ ! "$panel_url" =~ ^https?:// ]]; then
    echo "站点域名不是合法的 http(s) 地址：$panel_url" >&2
    exit 1
fi
if [[ ! "$sub_url" =~ ^https?:// ]]; then
    echo "订阅域名不是合法的 http(s) 地址：$sub_url" >&2
    exit 1
fi

"$script_dir/fetch-kernel.sh" linux "$arch"
"$script_dir/build-helper.sh" linux "$arch"

cd "$app_dir"
# 窗口标题在 runner/CMakeLists.txt 里读这个环境变量，不走 --build-name
export ECYCLOUD_VERSION="$display_version"
# Flutter 只为宿主架构产出 Linux 产物，arm64 包需在 arm64 机器上构建
flutter build linux --release --build-name "$version" \
    --dart-define="ECYCLOUD_SITE_URL=$panel_url" \
    --dart-define="ECYCLOUD_SUB_URL=$sub_url" \
    --dart-define="ECYCLOUD_VERSION=$display_version"
cd "$root_dir"

bundle="$app_dir/build/linux/$arch/release/bundle"
if [[ ! -x "$bundle/ECYCloud" ]]; then
    echo "未找到 Flutter 产物：$bundle" >&2
    exit 1
fi

# helper 与内核同目录进 /opt/ecycloud；verifyGUICaller 只认这个 GUI 路径
stage_dir="$root_dir/build/linux/$arch/payload"
deps_dir="$root_dir/build/deps/linux-$arch"
rm -rf "$stage_dir"
mkdir -p "$stage_dir/opt/ecycloud" "$stage_dir/usr/share/applications"

cp -R "$bundle"/. "$stage_dir/opt/ecycloud/"
# 逐个点名：deps 是增量的，换内核后旧文件还在
install -m 0755 "$deps_dir/mihomo" "$stage_dir/opt/ecycloud/mihomo"
install -m 0755 "$deps_dir/ecycloud-helper" "$stage_dir/opt/ecycloud/ecycloud-helper"
install -m 0644 "$deps_dir/LICENSE.mihomo.txt" "$stage_dir/opt/ecycloud/LICENSE.mihomo.txt"
# geodata 与内核同目录：缺了内核会按 geox-url 同步下载，面板地址在目标网络不可达
install -m 0644 "$deps_dir/geoip.metadb" "$stage_dir/opt/ecycloud/geoip.metadb"
install -m 0644 "$deps_dir/GeoSite.dat" "$stage_dir/opt/ecycloud/GeoSite.dat"
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

out_dir="$root_dir/build/installer"
mkdir -p "$out_dir"

# 三种形态的自更新资产后缀不同，客户端按这份标记决定该拉哪个包
mark_format() {
    printf '%s\n' "$1" > "$stage_dir/opt/ecycloud/package-format"
}

package_deb() {
    mark_format deb
    local control_dir="$stage_dir/DEBIAN"
    mkdir -p "$control_dir"
    sed -e "s/APP_VERSION/$version/" -e "s/APP_ARCH/$deb_arch/" \
        "$script_dir/installer/linux/control" > "$control_dir/control"
    install -m 0755 "$script_dir/installer/linux/postinst" "$control_dir/postinst"
    install -m 0755 "$script_dir/installer/linux/prerm" "$control_dir/prerm"
    # 构建用户不是 root，--root-owner-group 让载荷统一记为 root:root
    dpkg-deb --build --root-owner-group "$stage_dir" \
        "$out_dir/ECYCloud-$version-linux-$arch.deb"
    # DEBIAN 只是 deb 的控制目录，留着会混进 rpm 与 tar.gz 的载荷
    rm -rf "$control_dir"
}

package_rpm() {
    mark_format rpm
    local top_dir="$root_dir/build/linux/$arch/rpm"
    rm -rf "$top_dir"
    mkdir -p "$top_dir"
    rpmbuild -bb "$script_dir/installer/linux/ecycloud.spec" \
        --target "$rpm_arch" \
        --define "_topdir $top_dir" \
        --define "_rpmdir $out_dir" \
        --define "_rpmfilename ECYCloud-$version-linux-$arch.rpm" \
        --define "app_version $version" \
        --define "payload $stage_dir"
}

package_tar() {
    mark_format tar.gz
    local tar_dir="$root_dir/build/linux/$arch/tar"
    local tree_name="ECYCloud-$version-linux-$arch"
    rm -rf "$tar_dir"
    mkdir -p "$tar_dir/$tree_name"
    cp -a "$stage_dir/." "$tar_dir/$tree_name/"
    install -m 0755 "$script_dir/installer/linux/install.sh" "$tar_dir/$tree_name/install.sh"
    install -m 0755 "$script_dir/installer/linux/uninstall.sh" "$tar_dir/$tree_name/uninstall.sh"
    # 解包后由 install.sh 铺到系统目录，属主统一记为 root:root
    tar -C "$tar_dir" --owner=0 --group=0 -czf \
        "$out_dir/$tree_name.tar.gz" "$tree_name"
}

for format in $formats; do
    case "$format" in
        deb) package_deb ;;
        rpm) package_rpm ;;
        tar) package_tar ;;
        *) echo "未知打包形态 $format" >&2; exit 1 ;;
    esac
done

echo "安装包已生成：$out_dir"
