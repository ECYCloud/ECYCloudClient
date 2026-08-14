#!/usr/bin/env bash
# 构建 Android 客户端：libmihomo.aar + 按 ABI 分包的 Flutter APK。
# 用法: build-android.sh [--version 1.0.1] [--channel last|pre] [--build-number 1] [--panel-url https://站点域名] [--sub-url https://订阅域名] [--skip-kernel]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(dirname "$script_dir")"
app_dir="$root_dir/app"
version='1.0.1'
channel='last'
build_number='1'
panel_url=''
sub_url=''
skip_kernel=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --build-number) build_number="$2"; shift 2 ;;
        --panel-url) panel_url="$2"; shift 2 ;;
        --sub-url) sub_url="$2"; shift 2 ;;
        --skip-kernel) skip_kernel=1; shift ;;
        *) echo "未知参数 $1" >&2; exit 1 ;;
    esac
done

# versionName 与产物名只收纯号段，Pre 前缀只进界面展示串
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

# 编内核绑定要 JDK 17 + NDK，耗时以十分钟计；反复出包时可复用上一次的产物
if [[ "$skip_kernel" -eq 1 ]]; then
    if [[ ! -f "$app_dir/android/app/libs/libmihomo.aar" ]]; then
        echo "缺少 app/android/app/libs/libmihomo.aar，不能跳过内核构建" >&2
        exit 1
    fi
else
    "$script_dir/build-libmihomo.sh"
fi

# geodata 进 APK assets，首次启动由 BoxService.seedGeoData 铺进内核运行目录。
# 桌面端是随安装包放在内核旁边，Android 内核在进程内跑，只能走 assets 这条路
"$script_dir/fetch-geodata.sh" "$app_dir/android/app/src/main/assets"

cd "$app_dir"
# 必须用 --split-per-abi：仅 --target-platform 不会裁掉 libmihomo.aar 里其它 ABI 的 .so
flutter build apk --release --split-per-abi \
    --build-name "$version" --build-number "$build_number" \
    --dart-define="ECYCLOUD_SITE_URL=$panel_url" \
    --dart-define="ECYCLOUD_SUB_URL=$sub_url" \
    --dart-define="ECYCLOUD_VERSION=$display_version"

out_dir="$root_dir/build/installer"
mkdir -p "$out_dir"
apk_dir="$app_dir/build/app/outputs/flutter-apk"
# Flutter ABI 目录名 → 发布后缀（与 AppUpdate.assetSuffix 对齐；不用关联数组以兼容 macOS bash 3）
for entry in 'arm64-v8a:arm64' 'armeabi-v7a:arm' 'x86_64:x64'; do
    abi="${entry%%:*}"
    suffix="${entry##*:}"
    src="$apk_dir/app-$abi-release.apk"
    if [[ ! -f "$src" ]]; then
        echo "未找到 Flutter 产物：$src" >&2
        exit 1
    fi
    dest="$out_dir/ECYCloud-$version-android-$suffix.apk"
    install -m 0644 "$src" "$dest"
    echo "安装包已生成：$dest"
done
