#!/usr/bin/env bash
# 用官方 OpenWrt 25.12 SDK 编 luci-app-ecycloud 与 zh-cn / zh-tw 翻译包（apk）。
# 用法: build-openwrt.sh [--version 1.0.4] [--panel-url https://站点] [--sub-url https://订阅]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
pkg_dir="$root_dir/openwrt/luci-app-ecycloud"
version=''
panel_url=''
sub_url=''

sdk_release='25.12.5'
sdk_target='x86/64'
sdk_file="openwrt-sdk-${sdk_release}-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
sdk_url="https://downloads.openwrt.org/releases/${sdk_release}/targets/${sdk_target}/${sdk_file}"
sdk_sha256='0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c'

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) version="$2"; shift 2 ;;
		--panel-url) panel_url="$2"; shift 2 ;;
		--sub-url) sub_url="$2"; shift 2 ;;
		*) echo "未知参数 $1" >&2; exit 1 ;;
	esac
done

if [[ -z "$version" ]]; then
	version="$(sed -n 's/^version: \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$root_dir/app/pubspec.yaml" | head -n1)"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "版本号必须是 X.Y.Z，实际是「$version」" >&2
	exit 1
fi

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

if [[ ! -f "$pkg_dir/Makefile" ]]; then
	echo "找不到插件源码：$pkg_dir" >&2
	exit 1
fi

cache_dir="$root_dir/build/cache"
sdk_root="$root_dir/build/openwrt-sdk"
out_dir="$root_dir/build/installer"
mkdir -p "$cache_dir" "$out_dir"

tarball="$cache_dir/$sdk_file"
if [[ ! -f "$tarball" ]]; then
	echo "下载 OpenWrt SDK $sdk_release"
	curl -fL --retry 3 -o "$tarball.part" "$sdk_url"
	mv "$tarball.part" "$tarball"
fi
actual="$(sha256sum "$tarball" | awk '{print $1}')"
if [[ "$actual" != "$sdk_sha256" ]]; then
	echo "SDK 校验失败：期望 $sdk_sha256，实际 $actual" >&2
	exit 1
fi

rm -rf "$sdk_root"
mkdir -p "$sdk_root"
tar --zstd -xf "$tarball" -C "$sdk_root" --strip-components=1

git config --global --add safe.directory '*' || true

if [[ ! -f "$sdk_root/feeds.conf" ]]; then
	cp "$sdk_root/feeds.conf.default" "$sdk_root/feeds.conf"
fi

(
	cd "$sdk_root"
	./scripts/feeds update luci
	./scripts/feeds install luci-base
)

rm -rf "$sdk_root/package/luci-app-ecycloud"
cp -a "$pkg_dir" "$sdk_root/package/luci-app-ecycloud"

if [[ ! -s "$sdk_root/private-key.pem" ]]; then
	openssl ecparam -name prime256v1 -genkey -noout -out "$sdk_root/private-key.pem"
	openssl ec -in "$sdk_root/private-key.pem" -pubout > "$sdk_root/public-key.pem"
fi

export ECYCLOUD_SITE_URL="$panel_url"
export ECYCLOUD_SUB_URL="$sub_url"
export ECYCLOUD_VERSION="$version"

{
	echo 'CONFIG_PACKAGE_luci-app-ecycloud=y'
	echo 'CONFIG_PACKAGE_luci-i18n-ecycloud-zh-cn=y'
	echo 'CONFIG_PACKAGE_luci-i18n-ecycloud-zh-tw=y'
} >> "$sdk_root/.config"

(
	cd "$sdk_root"
	make defconfig
	make package/luci-base/host/compile -j"$(nproc)"
	make package/luci-app-ecycloud/compile \
		package/luci-i18n-ecycloud-zh-cn/compile \
		package/luci-i18n-ecycloud-zh-tw/compile \
		-j"$(nproc)"
)

mapfile -t apks < <(find "$sdk_root/bin/packages" -type f \( \
	-name 'luci-app-ecycloud-*.apk' -o \
	-name 'luci-i18n-ecycloud-zh-cn-*.apk' -o \
	-name 'luci-i18n-ecycloud-zh-tw-*.apk' \
\) | sort)

if [[ ${#apks[@]} -ne 3 ]]; then
	echo "期望 3 个 apk，实际 ${#apks[@]}：" >&2
	find "$sdk_root/bin/packages" -type f -name '*.apk' -print >&2 || true
	exit 1
fi

stage="$root_dir/build/openwrt-stage"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "${apks[@]}" "$stage/"
{
	echo "OpenWrt ${sdk_release}（apk）。先挂 mihomo 源并安装 mihomo（如 mihomo-meta；不要装 nikki），再装本目录里的包："
	echo "apk add --allow-untrusted ./luci-app-ecycloud-*.apk ./luci-i18n-ecycloud-*.apk"
} > "$stage/INSTALL.txt"

tgz="$out_dir/ECYCloud-${version}-openwrt-25.12.tar.gz"
tar -C "$stage" -czf "$tgz" .
echo "wrote $tgz"
ls -l "$stage"
