#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
pkg_dir="$root_dir/openwrt/luci-app-ecycloud"
version=''
channel='last'
panel_url=''
sub_url=''
openwrt='25.12'

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) version="$2"; shift 2 ;;
		--channel) channel="$2"; shift 2 ;;
		--panel-url) panel_url="$2"; shift 2 ;;
		--sub-url) sub_url="$2"; shift 2 ;;
		--openwrt) openwrt="$2"; shift 2 ;;
		*) echo "未知参数 $1" >&2; exit 1 ;;
	esac
done

case "$openwrt" in
	25.12)
		sdk_release='25.12.5'
		sdk_toolchain='gcc-14.3.0'
		sdk_compression='zst'
		sdk_sha256='0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c'
		package_format='apk'
		package_separator='-'
		;;
	24.10)
		sdk_release='24.10.5'
		sdk_toolchain='gcc-13.3.0'
		sdk_compression='zst'
		sdk_sha256='d3e8ea62fc1c12f93a9c808c2ef4c01b6e149ee240bcd5a74d15bebcbc385bdd'
		package_format='ipk'
		package_separator='_'
		;;
	23.05)
		sdk_release='23.05.6'
		sdk_toolchain='gcc-12.3.0'
		sdk_compression='xz'
		sdk_sha256='f22bdac5b702bb823a0ee802e9bbda2a56c0f7a2687e5090113b00910dac995f'
		package_format='ipk'
		package_separator='_'
		;;
	*) echo "不支持 OpenWrt $openwrt，只能是 23.05、24.10 或 25.12" >&2; exit 1 ;;
esac
sdk_file="openwrt-sdk-${sdk_release}-x86-64_${sdk_toolchain}_musl.Linux-x86_64.tar.${sdk_compression}"
sdk_url="https://downloads.openwrt.org/releases/${sdk_release}/targets/x86/64/${sdk_file}"

if [[ -z "$version" ]]; then
	version="$(sed -n 's/^version: \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$root_dir/app/pubspec.yaml" | head -n1)"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "版本号必须是 X.Y.Z，实际是「$version」" >&2
	exit 1
fi

# 包版本字段与产物名只收纯号段，Pre 前缀只进 build.json 界面串
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

if [[ ! -f "$pkg_dir/Makefile" ]]; then
	echo "找不到插件源码：$pkg_dir" >&2
	exit 1
fi

cache_dir="$root_dir/build/cache"
sdk_root="$root_dir/build/openwrt-sdk-$openwrt"
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
tar -xf "$tarball" -C "$sdk_root" --strip-components=1

git config --global --add safe.directory '*' || true

if [[ ! -f "$sdk_root/feeds.conf" ]]; then
	cp "$sdk_root/feeds.conf.default" "$sdk_root/feeds.conf"
fi

(
	cd "$sdk_root"
	./scripts/feeds update luci
)

# 只要 luci.mk 与 po2lmo。feeds install luci-base 会把 lucihttp / rpcd-mod-luci
# 拉进编译图，SDK 里没有它们的 C 依赖，会编到一半炸掉。
po_src="$sdk_root/feeds/luci/modules/luci-base/src"
make -C "$po_src" clean po2lmo
mkdir -p "$sdk_root/staging_dir/host/bin" "$sdk_root/staging_dir/hostpkg/bin"
cp -a "$po_src/po2lmo" "$sdk_root/staging_dir/host/bin/po2lmo"
cp -a "$po_src/po2lmo" "$sdk_root/staging_dir/hostpkg/bin/po2lmo"

rm -rf "$sdk_root/package/luci-app-ecycloud"
cp -a "$pkg_dir" "$sdk_root/package/luci-app-ecycloud"

# luci.mk 的 Prepare 钩子曾因 include 顺序未执行，占位符会原样进包。拷进 SDK 后先写死。
build_json="$sdk_root/package/luci-app-ecycloud/root/usr/share/ecycloud/build.json"
sed -i \
	-e "s|__SITE_URL__|${panel_url}|g" \
	-e "s|__SUB_URL__|${sub_url}|g" \
	-e "s|__VERSION__|${display_version}|g" \
	"$build_json"
if grep -qE '__SITE_URL__|__SUB_URL__|__VERSION__' "$build_json"; then
	echo "build.json 仍有占位符" >&2
	exit 1
fi
chmod 0755 \
	"$sdk_root/package/luci-app-ecycloud/root/etc/init.d/ecycloud" \
	"$sdk_root/package/luci-app-ecycloud/root/usr/libexec/ecycloud-ctl"

if [[ "$package_format" == apk && ! -s "$sdk_root/private-key.pem" ]]; then
	openssl ecparam -name prime256v1 -genkey -noout -out "$sdk_root/private-key.pem"
	openssl ec -in "$sdk_root/private-key.pem" -pubout > "$sdk_root/public-key.pem"
fi

export ECYCLOUD_SITE_URL="$panel_url"
export ECYCLOUD_SUB_URL="$sub_url"
export ECYCLOUD_VERSION="$version"
export ECYCLOUD_CHANNEL="$channel"

{
	echo 'CONFIG_PACKAGE_luci-app-ecycloud=y'
	echo 'CONFIG_PACKAGE_luci-i18n-ecycloud-zh-cn=y'
	echo 'CONFIG_PACKAGE_luci-i18n-ecycloud-zh-tw=y'
	echo 'CONFIG_LUCI_CSSTIDY=n'
	echo 'CONFIG_LUCI_SRCDIET=n'
	echo 'CONFIG_LUCI_JSMIN=n'
} >> "$sdk_root/.config"

(
	cd "$sdk_root"
	make defconfig
	# defconfig 可能把上面几项改回去
	sed -i \
		-e 's/^CONFIG_LUCI_CSSTIDY=.*/# CONFIG_LUCI_CSSTIDY is not set/' \
		-e 's/^CONFIG_LUCI_SRCDIET=.*/# CONFIG_LUCI_SRCDIET is not set/' \
		-e 's/^CONFIG_LUCI_JSMIN=.*/# CONFIG_LUCI_JSMIN is not set/' \
		.config
	grep -q '^CONFIG_PACKAGE_luci-app-ecycloud=y' .config || echo 'CONFIG_PACKAGE_luci-app-ecycloud=y' >> .config
	grep -q '^CONFIG_PACKAGE_luci-i18n-ecycloud-zh-cn=y' .config || echo 'CONFIG_PACKAGE_luci-i18n-ecycloud-zh-cn=y' >> .config
	grep -q '^CONFIG_PACKAGE_luci-i18n-ecycloud-zh-tw=y' .config || echo 'CONFIG_PACKAGE_luci-i18n-ecycloud-zh-tw=y' >> .config
	make package/luci-app-ecycloud/compile -j"$(nproc)"
)

mapfile -t packages < <(find "$sdk_root/bin/packages" -type f \( \
	-name "luci-app-ecycloud${package_separator}*.${package_format}" -o \
	-name "luci-i18n-ecycloud-zh-cn${package_separator}*.${package_format}" -o \
	-name "luci-i18n-ecycloud-zh-tw${package_separator}*.${package_format}" \
\) | sort)

if [[ ${#packages[@]} -ne 3 ]]; then
	echo "期望 3 个 $package_format，实际 ${#packages[@]}：" >&2
	find "$sdk_root/bin/packages" -type f -name "*.${package_format}" -print >&2 || true
	exit 1
fi

main_package=''
for package in "${packages[@]}"; do
	if [[ "$(basename "$package")" == luci-app-ecycloud"${package_separator}"*."${package_format}" ]]; then
		main_package="$package"
		break
	fi
done
if [[ -z "$main_package" ]] || strings "$main_package" | grep -qE '__SITE_URL__|__SUB_URL__|__VERSION__'; then
	echo "luci-app-ecycloud $package_format 仍含 build.json 占位符" >&2
	exit 1
fi

stage="$root_dir/build/openwrt-stage-$openwrt"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "${packages[@]}" "$stage/"
{
	echo "OpenWrt ${openwrt}（${package_format}）。先安装适配本机的 mihomo 包（如 mihomo-meta；不要装 nikki），再在路由器 SSH 中安装本目录里的包："
	if [[ "$openwrt" == 23.05 ]]; then
		echo 'Nikki 源不提供 23.05 分支；须自行提供兼容且声明 PROVIDES:=mihomo 的内核包。'
	fi
	if [[ "$package_format" == apk ]]; then
		echo "apk add --allow-untrusted ./luci-app-ecycloud-*.apk ./luci-i18n-ecycloud-*.apk"
	else
		echo "opkg update"
		echo "opkg install ./luci-app-ecycloud_*.ipk ./luci-i18n-ecycloud-*.ipk"
	fi
} > "$stage/INSTALL.txt"

tgz="$out_dir/ECYCloud-${version}-openwrt-${openwrt}.tar.gz"
tar -C "$stage" -czf "$tgz" .
echo "wrote $tgz"
ls -l "$stage"
